// ============================================================================================
// HANDOFF CONTEXT (for Fable)
// ============================================================================================
// This is the iOS Bluetooth transport for a watch→phone data-transfer exercise. The watch buffers
// opaque data-point records; this file moves them to the phone WHILE THE PHONE SCREEN IS OFF.
// It is the production conformer of the `WhoopTransport` protocol defined in OffloadEngine.swift,
// and together the two files form the complete pipeline:
//
//     BackgroundBLETransport  ──complete frames──▶  OffloadEngine  ──chunks──▶  caller persists
//     (this file: radio +                          (OffloadEngine.swift:
//      screen-off survival)                         fast ack algorithm)
//
// WHY SCREEN-OFF NEEDS SPECIAL HANDLING ON iOS (each requirement → the mechanism used here):
//   1. When the screen locks, the app is SUSPENDED within seconds. To keep receiving, the app
//      must be relaunched/resumed by the system on Bluetooth events. That requires:
//        - Info.plist: `UIBackgroundModes: [bluetooth-central]` (the host app must declare this;
//          this repo's iOS target already does)
//        - Info.plist: `NSBluetoothAlwaysUsageDescription`
//        - A STABLE restore identifier passed to CBCentralManager
//          (`CBCentralManagerOptionRestoreIdentifierKey`) + handling `willRestoreState`, so a
//          killed/suspended app is relaunched in the background with its peripheral intact.
//   2. Background SCANNING is throttled: it requires explicit service UUIDs, coalesces duplicates,
//      and is slow. So scanning is used ONLY for first-time pairing (foreground). Reconnection
//      uses a PENDING CONNECT instead: `central.connect(peripheral)` has NO timeout — the system
//      holds it open indefinitely and wakes the app the moment the watch comes in range, screen
//      off or not. The watch's identifier is persisted so this works across app relaunches via
//      `retrievePeripherals(withIdentifiers:)`.
//   3. Unconfirmed writes can be SILENTLY DROPPED when the outgoing buffer is full — and the fast
//      offload algorithm (OffloadEngine) deliberately sends its per-chunk acks unconfirmed. A
//      dropped ack stalls the watch forever. So this transport paces every unconfirmed write
//      through a queue gated on `canSendWriteWithoutResponse`, drained again on the
//      `peripheralIsReady(toSendWriteWithoutResponse:)` callback. Nothing is fire-and-lost.
//   4. TIMERS DO NOT FIRE while suspended. Each Bluetooth delegate callback grants ~10s of
//      background runtime; between callbacks the process is frozen. So this file is 100%
//      event-driven: reconnects happen inline in `didDisconnect` (no "retry in 3s" timer), and
//      any stall watchdog belongs in the app layer as a "check staleness on each event" pattern.
//
// HOW TO WIRE IT TO THE ENGINE (no other files needed):
//
//     let transport = BackgroundBLETransport(config: .init(
//         restoreIdentifier: "com.example.watch.central",
//         serviceUUID: CBUUID(string: "..."),               // the watch's data service
//         writeCharacteristicUUID: CBUUID(string: "..."),   // commands → watch
//         notifyCharacteristicUUIDs: [CBUUID(string: "...")])) // data ← watch
//     let engine = OffloadEngine(transport: transport,
//                                makeKickoffFrame: { ... },  // see OffloadEngine.swift header
//                                makeAckFrame: { ... })
//     transport.onFrame = { engine.ingest($0) }              // complete frames, already reassembled
//     transport.onReady = { engine.begin() }                 // link up + write channel discovered
//     engine.onChunkReady = { frames, trim in
//         // persist `frames` durably, then:
//         engine.confirmDurable(trim: trim)
//     }
//
// WHAT'S DONE / WHAT'S LEFT:
//   - This file is complete and self-contained: it needs only CoreBluetooth + this module's
//     `Reassembler` (fragment → frame assembly) and `WhoopTransport`. iOS-only by design
//     (`#if os(iOS)`) — state restoration does not exist on macOS, so macOS builds compile it out.
//   - NOT YET WIRED: the app's BLEManager still owns the radio. Adopting this transport means the
//     app creates ONE BackgroundBLETransport (one restore identifier ↔ one central) and routes
//     its offload path through OffloadEngine as sketched above.
//   - Pairing UX: `startPairing()` must be called while the app is foregrounded (see point 2).
// ============================================================================================

#if os(iOS)
import Foundation
import CoreBluetooth

// MARK: - Configuration

/// Everything the transport needs to know about the watch's GATT layout. Kept as plain data so
/// the transport itself stays generic — it moves framed bytes, it doesn't know what's in them.
public struct BackgroundTransportConfig {
    /// MUST be stable across launches: iOS uses it to match a relaunched app back to the central
    /// it was running before it was killed. Changing it orphans the restored session.
    public let restoreIdentifier: String
    /// The primary service advertised by the watch (also the background-scan filter for pairing).
    public let serviceUUID: CBUUID
    /// The characteristic commands are written to (kickoff + acks).
    public let writeCharacteristicUUID: CBUUID
    /// The characteristics the watch streams data on; all are subscribed.
    public let notifyCharacteristicUUIDs: [CBUUID]
    /// Frame-length convention for reassembly (defaults to the classic envelope).
    public let family: DeviceFamily

    public init(restoreIdentifier: String,
                serviceUUID: CBUUID,
                writeCharacteristicUUID: CBUUID,
                notifyCharacteristicUUIDs: [CBUUID],
                family: DeviceFamily = .whoop4) {
        self.restoreIdentifier = restoreIdentifier
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUIDs = notifyCharacteristicUUIDs
        self.family = family
    }
}

// MARK: - BackgroundBLETransport

/// iOS CoreBluetooth conformer of `WhoopTransport` built for screen-off operation.
///
/// Lifecycle: `init` → (first time only, foreground) `startPairing()` → connect → `onReady` →
/// frames flow via `onFrame`. On disconnect it immediately re-issues a pending connect — the
/// system completes it whenever the watch returns, waking the app in the background. On app
/// relaunch (including a background relaunch triggered by a Bluetooth event while the screen is
/// off) `willRestoreState` hands back the live peripheral and the pipeline resumes untouched.
///
/// Isolation: `@MainActor`, and the CBCentralManager is created with `queue: .main`, so every
/// delegate callback already arrives on the actor's executor. Same pattern as the app's existing
/// BLE code.
@MainActor
public final class BackgroundBLETransport: NSObject, WhoopTransport {

    // MARK: Callbacks (the transport's entire outward surface)

    /// One COMPLETE frame, already reassembled from notification fragments. Feed straight into
    /// `OffloadEngine.ingest` (and/or any live-stream router).
    public var onFrame: (([UInt8]) -> Void)?
    /// Link is up AND the write characteristic is discovered — safe to `engine.begin()`.
    public var onReady: (() -> Void)?
    /// Link dropped. A pending reconnect has ALREADY been issued (unless the drop was requested
    /// via `disconnect()`); this is informational so the app can update state / abort the engine.
    public var onDisconnect: ((Error?) -> Void)?
    /// Diagnostic log line. Optional; the transport never blocks on it.
    public var onLog: ((String) -> Void)?

    // MARK: WhoopTransport

    /// Updated from `maximumWriteValueLength(for: .withoutResponse)` once connected. Starts at the
    /// BLE-minimum 20 so pre-connection reasoning is always conservative.
    public private(set) var maxWriteLength: Int = 20

    /// Send a fully-framed command. Confirmed writes go straight out (CoreBluetooth queues those
    /// internally). Unconfirmed writes — the fast algorithm's per-chunk acks — are paced through
    /// `pendingWrites` so a full outgoing buffer can never silently drop one (screen-off
    /// requirement 3 in the header).
    public func sendFrame(_ frame: [UInt8], acknowledged: Bool) {
        guard let p = peripheral, let ch = writeChar else {
            log("sendFrame dropped — not connected")
            return
        }
        if acknowledged {
            p.writeValue(Data(frame), for: ch, type: .withResponse)
        } else {
            pendingWrites.append(frame)
            drainPendingWrites()
        }
    }

    // MARK: State

    private let config: BackgroundTransportConfig
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Peripheral handed back by `willRestoreState`; adopted in `centralManagerDidUpdateState`
    /// (the central is not necessarily poweredOn yet when restoration fires).
    private var restoredPeripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var reassembler: Reassembler
    /// Unconfirmed writes awaiting buffer space; drained on `peripheralIsReady`.
    private var pendingWrites: [[UInt8]] = []
    private var intentionalDisconnect = false

    /// Where the paired watch's identifier is persisted so a fresh launch can reconnect with a
    /// pending connect instead of a (background-hostile) scan.
    private var knownPeripheralKey: String { config.restoreIdentifier + ".peripheral" }

    public init(config: BackgroundTransportConfig) {
        self.config = config
        self.reassembler = Reassembler(family: config.family)
        super.init()
        // The restore identifier is the whole ballgame for screen-off: it tells iOS "if you kill
        // or suspend this app, relaunch it in the background when this central has an event".
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: config.restoreIdentifier])
    }

    // MARK: Public control

    /// First-time discovery. Call ONLY while the app is in the foreground — background scans are
    /// throttled and coalesced by iOS (header, requirement 2). After the first successful connect
    /// the watch's identifier is persisted and pairing is never needed again; every subsequent
    /// launch reconnects via a pending connect.
    public func startPairing() {
        guard central.state == .poweredOn else {
            log("startPairing ignored — Bluetooth not powered on")
            return
        }
        intentionalDisconnect = false
        log("Scanning for service \(config.serviceUUID)…")
        central.scanForPeripherals(withServices: [config.serviceUUID], options: nil)
    }

    /// Tear the link down and stop auto-reconnecting (until `startPairing()` or relaunch).
    public func disconnect() {
        intentionalDisconnect = true
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: Internals

    /// Take ownership of a peripheral and persist its identifier for pending-connect reconnects.
    private func adopt(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        UserDefaults.standard.set(p.identifier.uuidString, forKey: knownPeripheralKey)
    }

    /// Reconnect the persisted watch WITHOUT scanning: retrieve the peripheral object by
    /// identifier and issue a pending connect. Returns false when no watch has been paired yet.
    private func reconnectKnownPeripheral() -> Bool {
        guard let raw = UserDefaults.standard.string(forKey: knownPeripheralKey),
              let id = UUID(uuidString: raw),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first else {
            return false
        }
        adopt(p)
        log("Pending connect issued for known watch \(p.identifier) (no timeout; wakes app in background)")
        central.connect(p, options: connectOptions)
        return true
    }

    private var connectOptions: [String: Any] {
        // Have the system surface unexpected drops even while we're backgrounded.
        [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
    }

    /// Push queued unconfirmed writes while the radio has buffer space. Called after every enqueue
    /// AND from `peripheralIsReady` — the two together guarantee eventual delivery in order.
    private func drainPendingWrites() {
        guard let p = peripheral, let ch = writeChar else { return }
        while !pendingWrites.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(Data(pendingWrites.removeFirst()), for: ch, type: .withoutResponse)
        }
    }

    private func log(_ s: String) { onLog?(s) }
}

// MARK: - CBCentralManagerDelegate

// `@preconcurrency`: the delegate protocols declare nonisolated requirements, but this class is
// @MainActor and the central was created with `queue: .main`, so every callback already arrives on
// the main actor. @preconcurrency encodes that contract (with a runtime isolation check) instead of
// leaving a compiler warning.
extension BackgroundBLETransport: @preconcurrency CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        if let p = restoredPeripheral {
            // Background relaunch path: pick up exactly where the killed process left off.
            restoredPeripheral = nil
            if p.state == .connected {
                log("Restored CONNECTED watch \(p.identifier) — re-discovering services")
                p.discoverServices([config.serviceUUID])
            } else {
                log("Restored watch \(p.identifier) not connected — issuing pending connect")
                central.connect(p, options: connectOptions)
            }
        } else if !reconnectKnownPeripheral() {
            log("No known watch — call startPairing() in the foreground")
        }
    }

    /// Screen-off requirement 1: iOS relaunched us in the background because our central had an
    /// event. Reclaim the peripheral NOW (delegate included) so no notification is missed; defer
    /// connect/discovery to `centralManagerDidUpdateState` (the central may not be poweredOn yet).
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        adopt(p)
        restoredPeripheral = p
        log("Restore: reclaimed watch \(p.identifier) (state \(p.state.rawValue))")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        log("Discovered \(peripheral.name ?? "watch") (rssi \(RSSI)) — connecting")
        central.stopScan()
        adopt(peripheral)
        central.connect(peripheral, options: connectOptions)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Fresh framing state per connection — no stale half-frame can bleed across links.
        reassembler = Reassembler(family: config.family)
        log("Connected — discovering services")
        peripheral.discoverServices([config.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        writeChar = nil
        // Queued unconfirmed writes are meaningless on a dead link; the engine's durable cursor
        // (OffloadEngine.durableTrim) is the recovery mechanism, not this queue.
        pendingWrites.removeAll()
        onDisconnect?(error)
        guard !intentionalDisconnect else {
            log("Disconnected (intentional)")
            return
        }
        // Screen-off requirement 4: NO retry timer (it would never fire while suspended). Re-issue
        // the pending connect inline — the system completes it whenever the watch is back in range
        // and wakes the app to resume, screen off or not.
        log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? "") — pending reconnect issued")
        central.connect(peripheral, options: connectOptions)
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "") — re-issuing pending connect")
        guard !intentionalDisconnect else { return }
        // Rare for a pending connect (usually transient resource pressure); re-arming keeps the
        // background wake path alive without any timer.
        central.connect(peripheral, options: connectOptions)
    }
}

// MARK: - CBPeripheralDelegate

extension BackgroundBLETransport: @preconcurrency CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == config.serviceUUID }) else {
            log("Service \(config.serviceUUID) not found")
            return
        }
        peripheral.discoverCharacteristics(
            [config.writeCharacteristicUUID] + config.notifyCharacteristicUUIDs, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == config.writeCharacteristicUUID {
                writeChar = c
                // The REAL negotiated ceiling for one unconfirmed write (ATT MTU − 3). Bigger MTU
                // = fewer packets per frame; the engine reads this via WhoopTransport.
                maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
                log("Write channel ready (maxWriteLength \(maxWriteLength))")
            } else if config.notifyCharacteristicUUIDs.contains(c.uuid) {
                peripheral.setNotifyValue(true, for: c)
                log("Subscribed \(c.uuid)")
            }
        }
        if writeChar != nil { onReady?() }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let data = characteristic.value else { return }
        // Each of these callbacks is also what grants background runtime while the screen is off —
        // the data itself keeps the process awake for the duration of the transfer.
        for frame in reassembler.feed([UInt8](data)) {
            onFrame?(frame)
        }
    }

    /// The radio freed buffer space — push the next queued unconfirmed writes. This is the second
    /// half of the no-dropped-acks guarantee (see `sendFrame`).
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainPendingWrites()
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}
#endif
