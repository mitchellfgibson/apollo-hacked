import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// CoreBluetooth engine for the WHOOP 5.0 / MG: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    /// Fast offload sequencer (Fable's engine): acks each chunk immediately + unconfirmed so the
    /// strap never stalls, tracks acked vs. durable trim for safe resume, and pipelines persistence
    /// off the critical path. Replaces the old serial `backfiller.begin()/ingest` drain loop.
    /// Rebuilt per session in `beginBackfill`. See OffloadEngine.swift.
    private var offloadEngine: OffloadEngine?
    /// Unconfirmed writes awaiting BLE buffer space (the engine's per-chunk acks). Paced through
    /// `canSendWriteWithoutResponse` and drained on `peripheralIsReady` so a full outgoing buffer
    /// can never silently drop an ack (which would stall the strap forever). Screen-off-safe.
    private var pendingUnconfirmedWrites: [[UInt8]] = []
    /// True while a historical offload session is in progress (frames route to the OffloadEngine).
    /// Mirrored to `state.backfilling` so the Settings sync circle can show active-sync animation.
    private var backfilling = false {
        didSet { Task { @MainActor in state.backfilling = backfilling } }
    }
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    /// Connect options that make CoreBluetooth keep the link sticky: fire connection/disconnection
    /// notifications (so the OS can wake us) and — on iOS — auto-reconnect the peripheral when it
    /// comes back into range without us re-scanning. Passed on every `connect(peripheral:)` so a
    /// momentary drop or out-of-range blip self-heals into a resumed offload with minimal dead air.
    static var reconnectOptions: [String: Any] {
        var opts: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
        ]
        // System-managed auto-reconnect is iOS 17+ only; on older iOS (and macOS) our own
        // didDisconnect → connect(peripheral:) retry loop covers the same ground.
        #if os(iOS)
        if #available(iOS 17.0, *) {
            opts[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }
        #endif
        return opts
    }
    private var keepAliveTick = 0
    #if os(macOS)
    /// Power assertion that keeps the Mac from going to IDLE system sleep while the strap is
    /// connected — otherwise a lid-closed / display-off Mac stops all BLE, the strap can't offload,
    /// and worn nights don't sync until you're back at the machine (the "worn but empty night" bug).
    /// Held only while connected; released on disconnect so it never keeps the Mac awake idly.
    private var sleepAssertionID: IOPMAssertionID = 0
    private var holdingSleepAssertion = false
    #endif
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while the Live screen wants the (heavy) realtime stream; keep-alive re-arms it.
    private var wantsRealtime = false
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// Consecutive auto-continued sessions since the last real progress or a HISTORY_COMPLETE.
    /// A session that ends on `timeout` while the strap is still behind us re-kicks IMMEDIATELY
    /// (instead of idling until the 15-min periodic floor) — that continuous drain is what turns a
    /// week-behind strap "live" overnight rather than in weeks. This counter bounds a pathological
    /// no-progress loop (strap wedged, serving nothing): after `maxAutoContinues` fruitless retries
    /// in a row we fall back to the slow periodic timer instead of hammering the link forever. Reset
    /// to 0 whenever a session actually persisted new hours (see `sawChunkThisSession`).
    private var autoContinueStreak = 0
    static let maxAutoContinues = 500   // multi-night backlogs need many small offload sessions;
                                        // the cap only guards a truly-wedged strap serving nothing
    /// Set true by `onChunkReady` the moment a session persists at least one chunk. Distinguishes a
    /// productive timeout (strap is streaming, just bursty — keep going) from a dead one (strap
    /// served nothing this session — back off).
    private var sawChunkThisSession = false
    /// Fired (main actor) after a productive backfill session persists new biometrics, so the owner
    /// (AppModel) can nudge the IntelligenceEngine to recompute recovery/strain/sleep right away
    /// instead of waiting for its 15-min timer. Debouncing lives on the AppModel side.
    var onBackfillProducedData: (() -> Void)?
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private var connectHandshakeDone = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    private var cmdCharacteristic: CBCharacteristic?
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    /// WHOOP 5/MG readiness: true once the puffin CLIENT_HELLO session has been opened. The MG
    /// analogue of `didBond` — it never bonds, so this gates historical offload for that family.
    private var puffinSessionOpen = false
    /// WHOOP 5/MG puffin notify chars, retained at discovery but subscribed only AFTER the bond
    /// confirms — the strap rejects them with "Authentication is insufficient" on an unauthenticated
    /// link, so subscribing pre-bond wedges the session. (Ported from the verified sibling codebase.)
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    /// Guards the once-per-connection 5/MG post-bond handshake (subscribe → SET_CLOCK → offload).
    /// didWriteValueFor re-fires on every later .withResponse ack, so the handshake must run once.
    private var whoop5SessionStarted = false
    private var clockRequested = false
    private var intentionalDisconnect = false
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    private var selectedModel: WhoopModel = .persisted

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    let deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (M3 state restoration).
        // iOS: pass CBCentralManagerOptionRestoreIdentifierKey so the system relaunches this app
        // in the background — screen off, app suspended — when the strap has data, invoking
        // `willRestoreState` with the previously connected peripheral.
        // macOS: state restoration is an iOS-only feature; init without options.
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        guard let path = try? StorePaths.defaultDatabasePath() else { return }
        guard let store = try? await WhoopStore(path: path) else { return }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 5.0 / MG")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture)
        // Strand: no server uploader/sync — all data stays on-device.
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
    }

    // MARK: Public API
    public func connect(model: WhoopModel = .persisted) {
        intentionalDisconnect = false
        selectedModel = model
        // Frame the inbound stream for the chosen family (WHOOP 5.0 / MG CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        backfiller?.family = model.deviceFamily   // historical decode must use family-correct offsets
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        log("Scanning for \(model.displayName)…")
        central.scanForPeripherals(
            withServices: [model.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    /// Hold an idle-system-sleep assertion so overnight offload keeps running with the lid closed.
    /// Idempotent. macOS-only; no-op elsewhere. Reason string shows in `pmset -g assertions`.
    private func acquireSleepAssertion() {
        #if os(macOS)
        guard !holdingSleepAssertion else { return }
        let reason = "NOOP: syncing WHOOP data" as CFString
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &sleepAssertionID)
        if ok == kIOReturnSuccess {
            holdingSleepAssertion = true
            log("Power: holding idle-sleep assertion (overnight sync)")
        }
        #endif
    }

    /// Release the idle-sleep assertion (on disconnect), so the Mac sleeps normally when idle.
    private func releaseSleepAssertion() {
        #if os(macOS)
        guard holdingSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        holdingSleepAssertion = false
        sleepAssertionID = 0
        log("Power: released idle-sleep assertion")
        #endif
    }

    public func disconnect() {
        intentionalDisconnect = true
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        guard let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            log("send(\(command.label)) ignored — not connected")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, and for a few commands a DIFFERENT
        // opcode/payload than WHOOP 4. Ported from the hardware-verified sibling codebase.
        if selectedModel.deviceFamily == .whoop5 {
            // Allowlist: only commands proven to work over puffin framing. Everything else is dropped
            // (their frame layout on 5/MG is unverified). Live (toggle HR, buzz), the firmware-alarm
            // family, the two historical-offload commands, and the clock pair (SET_CLOCK/GET_CLOCK are
            // MANDATORY before history — an un-clocked WHOOP 5 doesn't save sensor data to flash, so
            // offloads return zero body frames).
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .setAlarmTime || command == .getAlarmTime
                || command == .runAlarm || command == .disableAlarm
                || command == .sendHistoricalData || command == .historicalDataResult
                || command == .setClock || command == .getClock
                // READ-ONLY recon commands (safe — they don't change device state).
                || command == .reportVersionInfo || command == .getDeviceConfigValue
                || command == .getExtendedBatteryInfo || command == .getDataRange else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ on BOTH opcode AND payload (#48): opcode 0x13 (RUN_HAPTIC_
            // PATTERN_MAVERICK), not RUN_HAPTICS_PATTERN=79 (a real-MG capture showed 79 rejected with
            // result=0x03). Payload = the maverick "notify" body [0x01, effects(8), loopCtrl u16, loop].
            // puffinCommandFrame pads the inner to a 4-byte boundary, which this 12-byte payload needs.
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let puffinPayload: [UInt8] = isHaptics ? [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0] : payload
            seq = seq &+ 1
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: seq, payload: puffinPayload)
            p.writeValue(Data(frame), for: ch, type: writeType)
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(isHaptics ? " cmd=0x13" : ""))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Advance and return the rolling command sequence number. Shared by `send()` and the
    /// OffloadEngine's frame builders so every outbound COMMAND carries a fresh seq.
    private func nextSeq() -> UInt8 {
        seq = seq &+ 1
        return seq
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
    }

    /// Push queued unconfirmed writes (the OffloadEngine's per-chunk acks) while the radio has
    /// buffer space. Called after each enqueue in `sendFrame` AND from `peripheralIsReady` — the
    /// pair guarantees eventual, in-order delivery even when the outgoing buffer fills mid-offload.
    private func drainPendingUnconfirmedWrites() {
        guard let p = peripheral, let ch = cmdCharacteristic else { return }
        while !pendingUnconfirmedWrites.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(Data(pendingUnconfirmedWrites.removeFirst()), for: ch, type: .withoutResponse)
        }
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session driven by the fast `OffloadEngine`: build the engine,
    /// wire its persistence + completion callbacks, flip the routing flag, and let the engine kick
    /// the strap (SEND_HISTORICAL) and ack each chunk. Arms the idle watchdog.
    private func beginBackfill() {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return
        }
        guard let backfiller else {
            // Store not ready yet. Do NOT force live HR — the type-47 backfill is the metric
            // source. Just log; the next periodic backfill tick will run once the store is ready.
            log("Backfill: store not ready — deferring to next periodic tick")
            return
        }
        backfilling = true
        sawChunkThisSession = false   // fresh session: no productive chunk yet

        // Silence the continuous live realtime flood for the duration of the offload. On this
        // firmware the strap streams type-40/43 frames UNPROMPTED, which eat BLE airtime the
        // historical offload needs. `toggleRealtimeHR [0x00]` is the one mute that's actually framed
        // for WHOOP 5/MG (stopRawData/toggleIMUMode aren't on the puffin allowlist — they'd be
        // dropped); restored in exitBackfilling if the Live screen wants it.
        send(.toggleRealtimeHR, payload: [0x00])

        // Build the fast engine. Its frames route back through THIS BLEManager (the WhoopTransport):
        // the SEND_HISTORICAL kickoff goes out .withResponse; per-chunk acks go out UNconfirmed +
        // paced. Payload MUST be [0x00], NOT empty (verified on-device: empty → 0 frames; the Mac
        // ground-truth offload uses [0x00] too).
        // Family-aware frame builders: a WHOOP 5/MG strap needs the puffin (CRC16) envelope, verified
        // on-device to trigger the type-47 offload; WHOOP 4 keeps the legacy CRC8 framing.
        let engine = OffloadEngine(
            transport: self,
            family: selectedModel.deviceFamily,
            makeKickoffFrame: { [weak self] in
                guard let self else { return [] }
                let seq = self.nextSeq()
                switch self.selectedModel.deviceFamily {
                case .whoop5: return WhoopCommand.sendHistoricalData.frameWhoop5(seq: seq, payload: [0x00])
                case .whoop4: return WhoopCommand.sendHistoricalData.frame(seq: seq, payload: [0x00])
                }
            },
            makeAckFrame: { [weak self] endData in
                guard let self else { return [] }
                let seq = self.nextSeq()
                switch self.selectedModel.deviceFamily {
                case .whoop5: return WhoopCommand.historicalDataResult.frameWhoop5(seq: seq, payload: [0x01] + endData)
                case .whoop4: return WhoopCommand.historicalDataResult.frame(seq: seq, payload: [0x01] + endData)
                }
            })
        engine.onChunkReady = { [weak self] frames, trim in
            // Persist off the critical path — the ack for this chunk has ALREADY gone out, so the
            // strap is streaming the next chunk while this runs. On durable success, advance the
            // engine's safe resume cursor; on failure the durable cursor stays behind and the next
            // session re-pulls the chunk (safe-trim preserved).
            guard let self else { return }
            self.armBackfillTimeout()   // genuine offload progress — keep the watchdog alive
            self.sawChunkThisSession = true   // productive session → a timeout means "bursty", re-kick
            Task { @MainActor in
                if await self.backfiller?.persistChunk(frames: frames, trim: trim) == true {
                    engine.confirmDurable(trim: trim)
                    await self.recomputeSyncProgress()   // fill the sync ring as history lands
                }
            }
        }
        engine.onComplete = { [weak self] _ in
            self?.exitBackfilling(reason: "HISTORY_COMPLETE")
        }
        offloadEngine = engine
        engine.begin()              // sends SEND_HISTORICAL (.withResponse) via sendFrame
        armBackfillTimeout()
        log("Backfill: session started — fast offload engine kicked")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    /// The packet-type byte lives at a different offset per family: WHOOP 4 puts it at frame[4],
    /// WHOOP 5/MG (puffin) at frame[8] (after the larger CRC16 header). Reading the wrong offset
    /// made every puffin type-47 historical frame look like a non-offload frame, so the engine was
    /// never fed and the backfill session timed out instead of completing. This is that fix.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        let typeOffset: Int
        switch family {
        case .whoop5: typeOffset = 8
        case .whoop4: typeOffset = 4
        }
        guard frame.count > typeOffset else { return false }
        switch frame[typeOffset] {
        case 47, 48, 49, 50: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Strap went silent mid-offload: abort the engine WITHOUT acking pending chunks (the
            // durable strap_trim cursor means the next session safely resumes from what's on disk).
            self.offloadEngine?.abort()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    /// Restore the live stream after backfill muted it. Only re-arm the heavy realtime/raw flood if
    /// the Live screen actually wants it (`wantsRealtime`); otherwise leave it off — the lightweight
    /// standard 0x2A37 HR keeps recording regardless, and a muted flood means the NEXT backfill gets
    /// full airtime. Called only when draining has actually stopped, never between auto-continue hops.
    private func restoreLiveStreamAfterBackfill() {
        if wantsRealtime { send(.toggleRealtimeHR, payload: [0x01]) }
    }

    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        offloadEngine = nil
        pendingUnconfirmedWrites.removeAll()
        let wasProductive = sawChunkThisSession
        log("Backfill: session ended — reason=\(reason) productive=\(wasProductive)")
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?

        // Recompute dashboard scores (recovery / strain / SLEEP) from the biometrics we just landed.
        // The IntelligenceEngine (AppModel) owns this — it stages sleep AND scores strain/recovery
        // together and persists under the "-noop" computed source that the dashboard merges. We just
        // nudge it (debounced) after new data so nights populate right after a sync instead of only
        // on the 15-min timer.
        if wasProductive { onBackfillProducedData?() }

        // CONTINUOUS DRAIN: the 15-min periodic timer alone means each ~60s burst is followed by
        // ~14 min of idle — so a week-behind strap catches up in weeks, not overnight. Instead, when
        // a session ends on the idle watchdog (NOT HISTORY_COMPLETE) but it was productive (streamed
        // real chunks — the strap is just bursty behind the type-43 flood), re-kick immediately so
        // the drain runs back-to-back until the strap actually signals HISTORY_COMPLETE. Guards:
        //   • only while still connected and the session actually produced data,
        //   • bounded by `maxAutoContinues` so a wedged strap that serves nothing can't hot-loop.
        // NOTE: this used to also bail on `state.isLive`, but that was the "worn nights don't sync"
        // bug — `isLive` is HR-freshness-based, and live HR keeps it TRUE even while GRAVITY (which
        // only arrives via the type-47 offload) is still missing for whole nights. So a productive
        // session would drain a little, `isLive` read true, and the drain stopped with nights still
        // un-pulled. A productive session means the strap HAS more to give: keep going until it
        // signals HISTORY_COMPLETE (genuinely caught up) or the streak cap trips.
        //
        // BUT the strap sends HISTORY_COMPLETE for the CURRENT offload window, not "you now have
        // everything" — on a multi-night backlog it completes many small windows in a row. Treating
        // every HISTORY_COMPLETE as "done" is why the drain went burst-then-die and worn nights never
        // came in. So on a *productive* HISTORY_COMPLETE we re-kick anyway (it just gave us data →
        // there may be more), bounded by the streak cap. Only a NON-productive completion (the strap
        // served nothing new) is the real "caught up" signal that stops the loop.
        if !state.connected || !wasProductive {
            autoContinueStreak = 0
            restoreLiveStreamAfterBackfill()   // done draining — bring back live HR if the user wants it
            return
        }
        guard autoContinueStreak < BLEManager.maxAutoContinues else {
            log("Backfill: auto-continue cap reached (\(BLEManager.maxAutoContinues)) — deferring to periodic timer")
            autoContinueStreak = 0
            restoreLiveStreamAfterBackfill()
            return
        }
        autoContinueStreak += 1
        log("Backfill: auto-continue #\(autoContinueStreak) — strap still behind, re-kicking now")
        // Small hop so this teardown fully unwinds (offloadEngine niled, flags cleared) before the
        // next session builds a fresh engine. Bypasses the BackfillPolicy floor deliberately: this is
        // active catch-up, not the periodic heartbeat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.state.connected, !self.backfilling else { return }
            self.beginBackfill()
        }
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    /// Recompute the sync-ring coverage %: distinct hours we have HR for ÷ hours in the strap's
    /// ~14-day stored window. This measures true completeness (gaps included), so a fresh live-HR
    /// frontier can't mask a week of missing history. Cheap COUNT-DISTINCT; called after offloads.
    /// Freshness-based sync progress. The old coverage metric (distinct HR hours ÷ 336 calendar
    /// hours) was wrong for a wrist strap: every hour you don't wear it (shower, gym, charging) is a
    /// permanent "hole" that can NEVER be filled — nothing was recorded there — so it capped around
    /// ~16% no matter how perfectly we synced. What "caught up / live / seamless" actually means is
    /// that our newest persisted record is close to NOW *and* the worn history behind it is filled.
    /// The ring reads "Live" (full) only when BOTH hold — "current AND complete", the meaning the
    /// user asked for. Neither half alone is honest:
    ///   • freshness alone → says Live the instant a live HR arrives, even with a week of holes behind,
    ///   • raw calendar coverage → can never reach 100% because off-wrist hours look like permanent holes.
    /// So progress = completeness, GATED by freshness:
    ///   • FRESHNESS: newest record must be within `liveWithinSeconds` (90 min) to count as caught-up
    ///     to the present; if we're further behind than that, the ring can't read full regardless of
    ///     completeness (we're demonstrably behind on new data).
    ///   • COMPLETENESS: covered ÷ (covered + small-holes), where small-holes are empty hours INSIDE a
    ///     wear session (≤3h gaps). 1.0 when every worn hour is drained; drops only for real
    ///     mid-session holes (an interrupted sync), never for off-wrist time. See `wearCompleteness`.
    /// The published value is the completeness fraction, scaled down by a stale-newest penalty so a
    /// strap we haven't heard from in days can't sit at a high number. nil data → 0.
    static let liveWithinSeconds = 90 * 60
    @MainActor
    func recomputeSyncProgress() async {
        let now = Int(Date().timeIntervalSince1970)
        guard let behind = await collector?.secondsBehind(now: now) else {
            state.syncProgress = 0
            return
        }
        let window = 14 * 24 * 3600
        let from = now - window
        let (covered, smallHoles) = await collector?.wearCompleteness(from: from, to: now) ?? (0, 0)

        // COMPLETENESS: fraction of worn hours we've actually pulled (off-wrist gaps excluded).
        let completeness: Double = covered + smallHoles > 0
            ? Double(covered) / Double(covered + smallHoles)
            : 0.0

        // FRESHNESS gate: 1.0 while caught up to the present (≤90 min behind), ramping to 0 as the
        // newest record recedes toward the full window. This is what stops a strap we lost contact
        // with days ago from showing "complete" off stale history.
        let live = BLEManager.liveWithinSeconds
        let freshness: Double
        if behind <= live {
            freshness = 1.0
        } else {
            freshness = max(0.0, min(1.0, Double(window - behind) / Double(window - live)))
        }

        // Full ring (== isLive) only when BOTH are essentially 1. The product also means a big
        // mid-session hole OR a stale newest each visibly pull the ring down — honest either way.
        state.syncProgress = max(0.0, min(1.0, completeness * freshness))
    }

    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            await recomputeSyncProgress()                 // update the Settings sync circle
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                send(.setClock, payload: BLEManager.setClockPayload())
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + the session is ready and NOT already mid-backfill. `sessionReady` is the
    /// family-appropriate readiness signal: WHOOP 4 sets it via the confirmed-write bond
    /// (`bonded`), while WHOOP 5/MG (which never bonds) sets it once the puffin CLIENT_HELLO
    /// session has opened. Extracted so the gate is unit-testable without a CoreBluetooth seam.
    static func shouldRunPeriodicBackfill(connected: Bool, sessionReady: Bool, backfilling: Bool) -> Bool {
        connected && sessionReady && !backfilling
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable the heavy realtime stream (type-40/43) and remember we want it re-armed by keep-alive.
    public func startRealtime() { wantsRealtime = true; send(.toggleRealtimeHR, payload: [0x01]) }
    /// Stop the realtime stream. The lightweight 0x2A37 HR keeps recording continuously regardless.
    public func stopRealtime() { wantsRealtime = false; send(.toggleRealtimeHR, payload: [0x00]) }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        // Readiness is family-specific: WHOOP 4 bonds (`didBond`); WHOOP 5/MG NEVER bonds and instead
        // opens the puffin session (`puffinSessionOpen`). Gating on `didBond` alone meant keep-alive —
        // battery polling AND the stall-recovery bounce — never ran at all for a 5/MG strap, so a
        // silently-wedged 5/MG link had nothing to kick it back to life. This is that fix.
        let ready: Bool
        switch selectedModel.deviceFamily {
        case .whoop5: ready = puffinSessionOpen
        case .whoop4: ready = didBond
        }
        guard state.connected, ready else { return }
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled — bounce it
        // (the fast reconnect re-establishes and resumes streaming). But NOT mid-backfill: an offload
        // of sparse history (long off-wrist gaps) can legitimately go quiet for a while, and the
        // backfill's own 60s idle watchdog already handles a genuinely stalled offload by RESUMING
        // it — bouncing the whole link there would throw away an active, productive session.
        if !backfilling && Date().timeIntervalSince(lastDataAt) > 120 {
            log("No data for >120s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        if wantsRealtime { send(.toggleRealtimeHR, payload: [0x01]) }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        let interval = BLEManager.backfillIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        // WHOOP 4 readiness = bonded; WHOOP 5/MG readiness = puffin session opened (never bonds).
        let sessionReady: Bool
        switch selectedModel.deviceFamily {
        case .whoop5: sessionReady = puffinSessionOpen
        case .whoop4: sessionReady = state.bonded
        }
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, sessionReady: sessionReady, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        beginBackfill()
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// Sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then SET_ALARM_TIME.
    /// The strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the guaranteed fixed-time fallback path —
    /// the smart-wake layer (`SmartAlarmController`) fires on top of this if conditions are met,
    /// but this firmware alarm always fires as the safety net.
    ///
    /// On-device verification needed: confirm the strap ACKs SET_ALARM_TIME and that the
    /// alarm persists across BLE disconnect (cannot be verified in the simulator).
    func armStrapAlarm(at date: Date) {
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        send(.setClock, payload: BLEManager.setClockPayload())
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        log("Alarm: armed for \(date) (epoch \(epochSec))")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// Fire an immediate alarm buzz on the strap for testing.
    ///
    /// WHOOP 4: RUN_HAPTICS_PATTERN (cmd 79) patternId=2 + RUN_ALARM (68). WHOOP 5/MG: those are
    /// ACK'd but do NOT drive the motor — the 5/MG firmware uses RUN_HAPTIC_PATTERN_MAVERICK (cmd 19)
    /// with a single pattern-id byte. Verified on real MG hardware (2026-07-09): payload [2] buzzes.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    /// TEMP READ-ONLY RECON: fire the safe GET_* commands to map the device's config/version, so we
    /// can learn what controls historical-offload content before any risky config WRITE. Responses
    /// are dumped to stderr (see processDecodedFrame RECON-RESP). Purely read-only — no device state
    /// changes. `getDeviceConfigValue` is probed across a few plausible config keys.
    func runProtocolRecon() {
        log("RECON: firing read-only version/config queries")
        send(.reportVersionInfo, payload: [0x00])
        send(.getExtendedBatteryInfo, payload: [0x00])
        // GET_DEVICE_CONFIG_VALUE(121): payload is a config-key selector (unknown). Probe keys 0..15;
        // each just READS a value back, changing nothing. We look for one whose response looks like a
        // record-type / optical-save flag.
        for key in 0..<16 {
            send(.getDeviceConfigValue, payload: [UInt8(key)])
        }
    }

    func testAlarmBuzz() {
        // Send runHapticsPattern — for 5/MG, send() REMAPS this to the maverick buzz (cmd 0x13 + the
        // correct 12-byte payload); for WHOOP 4 it's the native pattern. Both confirmed writes, plus
        // runAlarm as belt-and-suspenders. Matches the verified sibling codebase's buzzStrapOnce().
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0], writeType: .withResponse)
        switch selectedModel.deviceFamily {
        case .whoop5:
            send(.runAlarm, payload: AlarmPayload.runAlarmRev2(), writeType: .withResponse)  // rev2 [0x02, id]
            log("Alarm: MG buzz fired (maverick cmd-0x13 + runAlarm rev2, confirmed)")
        case .whoop4:
            send(.runAlarm, payload: [0x01], writeType: .withResponse)
            log("Alarm: test buzz fired (patternId=2, runAlarm)")
        }
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else { return }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present.
        if !m.rr.isEmpty { state.rr = m.rr }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value.
        if m.hr >= 30 && m.hr <= 220 { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - WhoopTransport (fast offload engine seam)
extension BLEManager: WhoopTransport {
    /// The negotiated ceiling for one unconfirmed write. Read from the peripheral once connected;
    /// falls back to the BLE minimum (20) before the write channel is known.
    public var maxWriteLength: Int {
        guard let p = peripheral else { return 20 }
        return p.maximumWriteValueLength(for: .withoutResponse)
    }

    /// Send a fully-framed command on behalf of the OffloadEngine. Confirmed writes (the
    /// SEND_HISTORICAL kickoff) go straight out; unconfirmed writes (per-chunk acks) are paced
    /// through `pendingUnconfirmedWrites` so a full outgoing buffer can never silently drop an ack.
    public func sendFrame(_ frame: [UInt8], acknowledged: Bool) {
        guard let p = peripheral, let ch = cmdCharacteristic else {
            log("sendFrame dropped — not connected")
            return
        }
        if acknowledged {
            p.writeValue(Data(frame), for: ch, type: .withResponse)
        } else {
            pendingUnconfirmedWrites.append(frame)
            drainPendingUnconfirmedWrites()
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        guard central.state == .poweredOn else { return }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: BLEManager.reconnectOptions)
            } else {
                p.discoverServices([
                    selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
                ])
            }
        } else {
            connect()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: BLEManager.reconnectOptions)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        restoredPeripheral = nil
        state.connected = true
        acquireSleepAssertion()   // keep the Mac awake enough to drain the strap overnight
        log("Connected — discovering services")
        peripheral.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        state.connected = false
        releaseSleepAssertion()   // let the Mac sleep normally once the strap is gone
        didBond = false
        puffinSessionOpen = false
        whoop5SessionStarted = false
        whoop5NotifyCharacteristics.removeAll()
        clockRequested = false
        connectHandshakeDone = false
        // Reset backfill state so the next connect starts a fresh offload.
        backfillStarted = false
        backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        offloadEngine = nil
        pendingUnconfirmedWrites.removeAll()
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if !intentionalDisconnect {
            // Reconnect FAST (1s, was 3s) to minimise dead air — every second disconnected is a
            // second not draining. Prefer `connect(peripheral)` over a fresh scan when we still hold
            // the peripheral: CoreBluetooth can re-establish a known link far quicker than a scan +
            // discover, and with `NotifyOnConnection` it will keep trying even if the strap is
            // momentarily out of range (it fires didConnect the instant it's reachable again).
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); reconnecting in 1s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.intentionalDisconnect else { return }
                if let p = self.peripheral {
                    self.central.connect(p, options: BLEManager.reconnectOptions)
                } else {
                    self.connect()
                }
            }
        } else {
            log("Disconnected (intentional)")
        }
    }

    /// A connect ATTEMPT failed (distinct from an established link dropping). Previously a no-op —
    /// so a failed attempt left the link dead until some other path happened to rescan. Retry it,
    /// so a transient failure (strap briefly unreachable) self-heals instead of stalling the flow.
    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? ""); retrying in 1s")
        guard !intentionalDisconnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.intentionalDisconnect else { return }
            self.central.connect(peripheral, options: BLEManager.reconnectOptions)
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        didBond = true
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            p.discoverServices([
                selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
            ])
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                // Definitively a 5/MG here — set the family on ALL family-dependent decoders NOW, on
                // every connect path (fresh OR state-restoration, which bypasses connect()). Without
                // this a restored connection decoded puffin frames with the WHOOP-4 parser → 0 records.
                selectedModel = .whoop5mg
                reassembler = Reassembler(family: .whoop5)
                router.family = .whoop5
                backfiller?.family = .whoop5
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // EXPERIMENTAL WHOOP 5.0/MG: a 5/MG strap starts a session with the static CLIENT_HELLO
                // frame, not the WHOOP4 confirmed-write bond. We write it UNacknowledged (it is a
                // complete framed command), so the WHOOP4 didWriteValueFor bond+handshake path never
                // fires for a 5/MG strap. Live HR/battery come from the standard profiles; this just
                // opens the puffin session. Unverified on real MG hardware.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // Write CLIENT_HELLO with .withResponse so CoreBluetooth runs just-works bonding
                    // AND didWriteValueFor fires — that callback is where we mark the link established
                    // and (deferred) subscribe the puffin notify chars. The strap rejects those chars
                    // with "Authentication is insufficient" until the link is encrypted, so subscribing
                    // here (pre-bond) would wedge the session. (Ported from the verified sibling repo.)
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (triggers bonding).")
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                    puffinSessionOpen = true
                }
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                peripheral.setNotifyValue(true, for: c)
                log("Subscribed \(c.uuid)")
                // The strap may not PUSH a battery notification (value only notifies on change), so
                // actively read the current level once on connect — otherwise battery% stays blank.
                if c.uuid == BLEManager.batteryChar {
                    peripheral.readValue(for: c)
                    log("Battery: active read requested")
                }
            default:
                // WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): RETAIN but do NOT
                // subscribe yet — the strap rejects them pre-bond. didWriteValueFor subscribes them
                // once the CLIENT_HELLO .withResponse write confirms the encrypted link.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                    log("Retained puffin notify \(c.uuid) (subscribe deferred to post-bond)")
                }
            }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            return
        }

        // WHOOP 5/MG post-bond lifecycle (ported from the verified sibling repo). The CLIENT_HELLO
        // .withResponse ack means the encrypted link is up. Now — and ONLY now — subscribe the puffin
        // notify chars (rejected pre-bond), then clock the strap and kick the offload. Do NOT fall
        // through to the WHOOP4 handshake (the strap rejects WHOOP4-framed commands).
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing puffin notify chars.")
            }
            // Idempotent (safe on every re-entry): subscribe any not-yet-subscribed puffin chars.
            for c in whoop5NotifyCharacteristics where !c.isNotifying {
                peripheral.setNotifyValue(true, for: c)
                log("Subscribed \(c.uuid) (puffin, post-bond)")
            }
            // Once-per-connection handshake: SET_CLOCK before history (an un-clocked WHOOP 5 discards
            // sensor data — "RTC timestamp invalid; not saving to flash" — so offloads return metadata
            // only, zero body frames), then trigger the offload after the subscriptions settle.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks beginBackfill()'s guard
                send(.setClock, payload: BLEManager.setClockPayload())
                send(.getClock, payload: [])
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.requestSync(.connect)
                }
                startBackfillTimer()
                startKeepAlive()   // 5/MG never bonds, so this was never started — no stall recovery
                                   // or battery polling on this family until now. Keeps the link warm.
                // Confirmation buzz so the wearer feels the strap is bonded + the command channel live.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.testAlarmBuzz()
                }
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        send(.setClock, payload: BLEManager.setClockPayload())
        if clockRef == nil && !clockRequested {
            clockRequested = true
            send(.getClock, payload: [])   // the strap expects GET_CLOCK with an EMPTY payload;
                                           // the app's old default [0x00] is a wrong length the strap ignores.
                                           // (Offload no longer depends on this — Backfiller falls back to an
                                           // identity clockRef — but a real correlation helps realtime decode.)
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
    }

    /// SET_CLOCK(10) payload = the strap's 8-byte form: [seconds u32 LE][subseconds
    /// u32 LE], subseconds in 1/32768 s (0 is fine). NOT the old 9-byte [u32 + 5 pad] — a wrong-length
    /// SET_CLOCK is ack-received but NOT latched, leaving the RTC lost so the strap won't serve type-47.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8]) -> Int? {
        dataRangeUnixExtremes(from: frame)?.newest
    }

    /// Both ends of the strap's stored range from a GET_DATA_RANGE response: the MIN and MAX u32 LE
    /// words that fall in the plausible-unix band. `oldest` is the crucial one for "is there history
    /// left to pull" — if the strap's oldest is earlier than OUR oldest persisted record, the strap
    /// is still holding data we've never offloaded. Returns nil if the body has no unix-like words.
    static func dataRangeUnixExtremes(from frame: [UInt8]) -> (oldest: Int, newest: Int)? {
        guard frame.count > 7 else { return nil }
        let body = Array(frame[7...]); var oldest: Int? = nil; var newest: Int? = nil; var i = 0
        while i + 4 <= body.count {
            let w = Int(body[i]) | Int(body[i+1]) << 8 | Int(body[i+2]) << 16 | Int(body[i+3]) << 24
            if w >= 1_700_000_000 && w <= 1_900_000_000 {
                oldest = min(oldest ?? w, w)
                newest = max(newest ?? 0, w)
            }
            i += 4
        }
        guard let o = oldest, let n = newest else { return nil }
        return (o, n)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
        case BLEManager.batteryChar:
            if let pct = bytes.first { state.setBattery(Double(pct)) } // 0x2A19 = percent
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // WHOOP 4 command/data/event channels — reassemble then run the full processing pipeline.
            for frame in reassembler.feed(bytes) { processDecodedFrame(frame) }
        default:
            // WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007). These now run the SAME
            // pipeline as WHOOP 4 (clock correlation, offload engine, collector): the type-47
            // historical store the strap serves over fd4b0005 is decoded by the existing engine.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) { processDecodedFrame(frame) }
            }
        }
    }

    /// Run a fully-reassembled, decoded frame through the shared processing pipeline: UI routing,
    /// data-range tracking, clock correlation, and either the historical OffloadEngine (during
    /// backfill) or the live Collector. Shared by the WHOOP 4 data channels and the WHOOP 5/MG
    /// puffin channels so both families feed the same type-47 decode + persistence path.
    private func processDecodedFrame(_ frame: [UInt8]) {
        router.handle(frame: frame)                       // UI (always)
        if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue,
           let range = BLEManager.dataRangeUnixExtremes(from: frame) {
            strapNewestTs = range.newest                  // feeds the liveness watchdog
            // Ground-truth completeness check: compare the strap's OLDEST stored record to ours. If
            // the strap holds data older than our oldest persisted HR, there's still history to pull
            // (the ring's in-DB completeness can't see this — it only measures holes WITHIN what we
            // already have). Logged so "is it 100% synced?" has a real answer, not an inference.
            Task { @MainActor in
                let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
                let strapOld = f.string(from: Date(timeIntervalSince1970: TimeInterval(range.oldest)))
                if let ourOldest = await collector?.oldestHRSampleTs() {
                    let behindOlderHours = (ourOldest - range.oldest) / 3600
                    if behindOlderHours > 1 {
                        self.log("Data range: strap oldest \(strapOld) is \(behindOlderHours)h BEFORE our oldest — MORE HISTORY TO PULL")
                    } else {
                        self.log("Data range: strap oldest \(strapOld) ≈ our oldest — no older history left on strap")
                    }
                } else {
                    self.log("Data range: strap oldest \(strapOld); we have no data yet")
                }
            }
        }
        // Clock correlation runs in both live and backfill modes. Once established it
        // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
        if clockRef == nil {
            let parsed = parseFrame(frame)
            if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                clockRef = ref
                collector?.clockRef = ref                  // unblocks buffered persistence
                backfiller?.clockRef = ref                 // unblocks historical chunk decode (persist path)
                log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                    log("Clock drift detected — issuing SET_CLOCK")
                    send(.setClock, payload: BLEManager.setClockPayload())
                }
            }
        }
        if backfilling {
            // Historical offload path: feed ONLY genuine offload frames (47/48/49/50) to the
            // fast OffloadEngine (which acks each chunk immediately + unconfirmed and hands the
            // frames to persistChunk off the critical path). Re-arm the idle watchdog on them.
            // The live type-40/43 flood is IGNORED by extractHistoricalStreams, so feeding it
            // to the engine would only add noise — drop it during offload.
            if BLEManager.isOffloadFrame(frame, family: selectedModel.deviceFamily) {
                armBackfillTimeout()
                offloadEngine?.ingest(frame)
            }
        } else {
            // Live path: synchronous ingest preserves delegate arrival order.
            collector?.ingest(frame)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    /// The radio freed outgoing buffer space — push the next queued unconfirmed writes (the
    /// OffloadEngine's per-chunk acks). Second half of the no-dropped-acks guarantee (see
    /// `sendFrame` / `drainPendingUnconfirmedWrites`), which keeps offload flowing screen-off.
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainPendingUnconfirmedWrites()
    }
}
