import Foundation

// ============================================================================================
// HANDOFF CONTEXT (for Fable)
// ============================================================================================
// This is a Bluetooth data-transfer exercise. The device is a wrist watch; the "records" are
// just opaque logged data points buffered on the watch. Nothing here is domain-specific — treat
// it purely as: pull a backlog of stored data-point records off a BLE peripheral as fast as
// possible, without dropping any.
//
// THE PROBLEM being solved:
//   The watch streams its stored backlog in chunks. After each chunk it sends a HISTORY_END
//   marker and then WAITS for the app to acknowledge that marker before sending the next chunk.
//   The old code did the acknowledgement only AFTER writing the chunk to disk, and sent it as a
//   confirmed BLE write (a full radio round-trip). So every chunk cost `disk-write + round-trip`
//   of idle time on the radio. That serialization — not the radio's raw speed — is the cap.
//
// THE FIX in this file (OffloadEngine):
//   - Acknowledge each chunk IMMEDIATELY (as soon as its bytes are snapshotted in memory) and as
//     an UNconfirmed write, so the watch is never stalled waiting on disk or a round-trip.
//   - Keep two cursors so we still never lose data: `ackedTrim` (told to the watch, keeps it
//     flowing) and `durableTrim` (only advanced once the caller confirms the chunk is written to
//     disk). If the app dies between ack and disk-write, the next run resumes from `durableTrim`
//     and safely re-pulls the un-written chunk.
//   - Because the ack no longer waits on disk, chunks pipeline: the watch streams chunk N+1 while
//     the caller is still writing chunk N.
//
// WHAT'S DONE / WHAT'S LEFT:
//   - This file + its test file (OffloadEngineTests.swift) are complete and self-contained. They
//     have NO CoreBluetooth and NO app dependencies — the algorithm is fully unit-testable with
//     MockTransport (no watch required). Run: `swift test --filter OffloadEngineTests`.
//   - NOT YET WIRED: BLEManager.swift still runs the old serial loop. Adopting this engine there
//     (BLEManager conforms to WhoopTransport; route HISTORY frames into `ingest`; call
//     `confirmDurable` after the store write lands) is the remaining integration step.
// ============================================================================================

// MARK: - WhoopTransport

/// The seam between "decide what to send / how to sequence the historical offload" and "actually
/// talk to CoreBluetooth". `BLEManager` is the production conformer (it forwards `send` to
/// `CBPeripheral.writeValue` and pumps received notifications into `OffloadEngine.ingest`).
/// `MockTransport` (below) is the test conformer — it records outbound writes and lets a test
/// script feed inbound frames, so the whole offload algorithm is exercisable WITHOUT a strap and
/// WITHOUT CoreBluetooth.
///
/// This protocol is deliberately tiny: the engine only needs to (a) push a framed command to the
/// strap and (b) be told when frames arrive. Everything else (scan/connect/bond/discovery) stays in
/// the CoreBluetooth layer and is out of scope for the throughput algorithm.
///
/// `@MainActor` to match `OffloadEngine`'s isolation: the engine calls the transport from the main
/// actor, and the production conformer runs its CoreBluetooth central on `queue: .main`, so the
/// whole pipeline lives on one actor — no cross-actor hops, Swift-6 clean.
@MainActor
public protocol WhoopTransport: AnyObject {
    /// The negotiated maximum bytes a single `.withoutResponse` write can carry. On CoreBluetooth
    /// this is `peripheral.maximumWriteValueLength(for: .withoutResponse)`. Larger = fewer writes per
    /// command; the engine uses it only to reason about pacing, never to fragment (WHOOP commands are
    /// already small, single-write frames).
    var maxWriteLength: Int { get }

    /// Send a fully-framed command to the strap's command characteristic.
    /// - Parameters:
    ///   - frame: the complete on-wire bytes (built via `WhoopCommand.frame(seq:payload:)`).
    ///   - acknowledged: `true` → `.withResponse` (a link-layer round-trip; use for the offload
    ///     kick-off and for acks that MUST be confirmed), `false` → `.withoutResponse` (fire-and-
    ///     forget, far cheaper — the key to keeping the strap streaming without stalls).
    func sendFrame(_ frame: [UInt8], acknowledged: Bool)
}

// MARK: - OffloadEngine

/// Testable historical-offload sequencer implementing the *fast* offload algorithm.
///
/// ## Why this exists
/// The legacy loop (see `Backfiller.finishChunk` / `BLEManager.ackHistoricalChunk`) is strictly
/// stop-and-wait: for every ~50-record chunk the strap will not send the next chunk until it
/// receives the HISTORY_END ack, and the ack was gated behind a *serial* `await insert → await
/// enqueueRaw → await setCursor` DB chain and then sent `.withResponse` (a full BLE round-trip).
/// So every chunk paid `DB-write latency + BLE round-trip` before the strap was unblocked. That
/// serialization — not the radio — is what caps throughput.
///
/// ## The faster algorithm (what this engine does)
/// 1. **Decouple the ack from persistence.** As soon as a chunk's frames are snapshotted in memory,
///    the engine emits the ack immediately (`onAckReady`) so the strap keeps streaming. The heavy
///    decode+persist work runs on the caller's side, off the critical path.
/// 2. **Preserve the safe-trim invariant.** The engine tracks two cursors: `ackedTrim` (told to the
///    strap, so it keeps flowing) and `durableTrim` (only advanced once the caller confirms the
///    chunk is on disk, via `confirmDurable(trim:)`). If the app dies between ack and disk-write,
///    the next session resumes from `durableTrim` and safely re-pulls the un-persisted chunk — no
///    data loss. This is the crucial correctness property; see `OffloadEngineTests`.
/// 3. **Pipeline.** Because the ack no longer waits on the DB, multiple chunks can be in flight:
///    the strap streams chunk N+1 while the caller is still persisting chunk N.
///
/// The engine is `@MainActor` to match `BLEManager`'s isolation, holds NO CoreBluetooth or app
/// (`Collector`/`WhoopStore`) types, and speaks only `WhoopTransport` + closures — so it unit-tests
/// deterministically against `MockTransport`.
@MainActor
public final class OffloadEngine {

    // MARK: Injected collaborators

    private let transport: WhoopTransport
    /// Builds the HISTORY_END ack frame for a given `end_data` (the verbatim 8 bytes the high-freq
    /// ack requires). Injected so the engine stays free of the app's `WhoopCommand` framing details
    /// while still emitting a real on-wire ack. In production: `WhoopCommand.historicalDataResult
    /// .frame(seq:payload: [0x01] + endData)`.
    private let makeAckFrame: (_ endData: [UInt8]) -> [UInt8]
    /// Builds the SEND_HISTORICAL_DATA kickoff frame. In production:
    /// `WhoopCommand.sendHistoricalData.frame(seq:payload: [0x00])`.
    private let makeKickoffFrame: () -> [UInt8]

    // MARK: Caller callbacks (persistence lives on the caller's side, OFF the ack critical path)

    /// A chunk's frames were snapshotted and are ready to persist. The caller decodes + writes them
    /// durably, then calls `confirmDurable(trim:)` with the SAME `trim` to advance the durable cursor.
    /// The ack to the strap has ALREADY been sent by the time this fires — persistence never blocks
    /// the strap.
    public var onChunkReady: ((_ frames: [[UInt8]], _ trim: UInt32) -> Void)?
    /// The strap signalled HISTORY_COMPLETE — the offload drained cleanly. `durableTrim` is the
    /// safe resume point for the next session.
    public var onComplete: ((_ durableTrim: UInt32?) -> Void)?

    // MARK: State

    /// True while a historical offload session is active.
    public private(set) var isOffloading = false
    /// Frames accumulated for the currently-open chunk (between START/END, or between two ENDs — the
    /// high-freq transfer mode sends ONE START then REPEATED ENDs, so a chunk closes on every END and the
    /// following records open the next chunk).
    private var chunk: [[UInt8]] = []
    private var chunkOpen = false
    /// Highest trim acked to the strap (keeps it streaming). May lead `durableTrim`.
    public private(set) var ackedTrim: UInt32?
    /// Highest trim the caller has confirmed is durably on disk. The SAFE resume cursor. Never
    /// advanced ahead of an actual `confirmDurable` — this is the safe-trim invariant.
    public private(set) var durableTrim: UInt32?
    /// Trims acked-but-not-yet-confirmed-durable. If HISTORY_COMPLETE arrives while this is non-empty
    /// the caller still has in-flight writes; correctness relies on those `confirmDurable` calls
    /// landing (or, on a crash, on the durable cursor being behind so the strap re-serves them).
    private var inFlightTrims: Set<UInt32> = []

    /// Device family — decides where the packet-type / metadata fields live in a frame. WHOOP 4
    /// (default, back-compat) uses the [4]-offset layout; WHOOP 5/MG (puffin) uses the [8]-offset
    /// layout. Without this the engine can't classify puffin HISTORY_START/END/COMPLETE and the
    /// offload session times out instead of draining.
    private let family: DeviceFamily

    public init(transport: WhoopTransport,
                family: DeviceFamily = .whoop4,
                makeKickoffFrame: @escaping () -> [UInt8],
                makeAckFrame: @escaping (_ endData: [UInt8]) -> [UInt8]) {
        self.transport = transport
        self.family = family
        self.makeKickoffFrame = makeKickoffFrame
        self.makeAckFrame = makeAckFrame
    }

    // MARK: Session control

    /// Kick off a historical offload. Sends SEND_HISTORICAL_DATA `.withResponse` (the one place a
    /// confirmed write is correct — it opens the session on a settled link) and arms accumulation.
    /// The high-freq transfer mode streams records immediately then sends ONE HISTORY_START, so we start
    /// with `chunkOpen == true` to avoid dropping the leading records.
    public func begin() {
        isOffloading = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
        transport.sendFrame(makeKickoffFrame(), acknowledged: true)
    }

    /// Abort the session without acking (watchdog fired / link stalled). No trim is advanced, so the
    /// next session safely resumes from `durableTrim`.
    public func abort() {
        isOffloading = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
        inFlightTrims.removeAll()
    }

    // MARK: Frame ingestion (the hot path)

    /// Feed one complete, reassembled frame into the offload state machine. Frames from the live
    /// stream (the continuous real-time data the watch also sends) are ignored here by design — the
    /// caller only routes genuine backlog-offload frames (packet types 47/48/49/50) to the engine,
    /// exactly as `BLEManager.didUpdateValueFor` already gates.
    public func ingest(_ frame: [UInt8]) {
        // HOT-PATH FAST-SKIP: a type-47 HISTORICAL_DATA frame is ALWAYS `.other` (only the type-49
        // METADATA frames carry START/END/COMPLETE). Type-47 records dominate the stream — and on
        // this firmware most are the 1–2 KB v20/v21 raw waveforms — so fully `parseFrame`-ing each
        // one just to reach the `.other` case was the offload's per-frame CPU sink. Read the packet
        // type from the header (frame[8] puffin / frame[4] whoop4) and, if it's data, append raw and
        // return without decoding. Metadata frames still take the full parse+classify path below.
        let typeOffset = family == .whoop5 ? 8 : 4
        if frame.count > typeOffset, frame[typeOffset] == 47 {
            if chunkOpen { chunk.append(frame) }
            return
        }
        switch classifyHistoricalMeta(parseFrame(frame, family: family)) {
        case .start:
            isOffloading = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(_, let trim):
            closeChunkAndAck(trim: trim, endFrame: frame)
        case .complete:
            isOffloading = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
            onComplete?(durableTrim)
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// Close the open chunk: snapshot its frames, **ack the strap immediately** (so it keeps
    /// streaming), then hand the snapshot to the caller for off-critical-path persistence. The ack
    /// is fire-and-forget (`.withoutResponse`): it advances the strap's trim without a blocking
    /// round-trip, which is the core speedup. The durable cursor is NOT advanced here — only
    /// `confirmDurable(trim:)` does that, preserving safe-trim.
    private func closeChunkAndAck(trim: UInt32, endFrame: [UInt8]) {
        guard let endData = Self.endData(from: endFrame, family: family) else { return }
        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // subsequent records open the next chunk

        // 1) Ack NOW — unblocks the strap for the next chunk before we touch persistence.
        ackedTrim = max(ackedTrim ?? 0, trim)
        inFlightTrims.insert(trim)
        transport.sendFrame(makeAckFrame(endData), acknowledged: false)

        // 2) Hand the snapshot off for durable persistence (runs on the caller, in parallel with
        //    the strap already streaming the next chunk). An empty END still advances the trim.
        onChunkReady?(frames, trim)
    }

    /// The caller calls this once a chunk identified by `trim` is durably on disk. Advances the safe
    /// resume cursor. Idempotent and order-tolerant: `durableTrim` only ever moves forward.
    public func confirmDurable(trim: UInt32) {
        inFlightTrims.remove(trim)
        durableTrim = max(durableTrim ?? 0, trim)
    }

    /// The 8-byte `end_data` the high-freq ack requires: metadata.data[10:18]. The inner record
    /// begins at frame[4] (WHOOP 4) or frame[8] (WHOOP 5/MG puffin — CRC16 header is 4 bytes larger);
    /// data starts 3 bytes further ([type,seq,cmd]), so end_data = data[10:18] =
    /// frame[innerStart+3+10 ..< +8]. Returns nil for a frame too short (guards a malformed END).
    public static func endData(from frame: [UInt8], family: DeviceFamily = .whoop4) -> [UInt8]? {
        let innerStart: Int
        switch family {
        case .whoop5: innerStart = 8
        case .whoop4: innerStart = 4
        }
        let dataStart = innerStart + 3 + 10   // + [type,seq,cmd] + 10 into metadata.data
        guard frame.count >= dataStart + 8 else { return nil }
        return Array(frame[dataStart..<(dataStart + 8)])
    }
}

// MARK: - MockTransport

/// In-memory `WhoopTransport` for hardware-free tests. Records every outbound write (frame + whether
/// it was acknowledged) so a test can assert the engine sent the right commands in the right order.
/// Feed inbound frames by calling `engine.ingest(_:)` directly — simulating the watch's stream
/// without CoreBluetooth. (`@MainActor` via the protocol; tests are annotated to match.)
@MainActor
public final class MockTransport: WhoopTransport {
    public struct Write: Equatable {
        public let frame: [UInt8]
        public let acknowledged: Bool
    }

    /// Every frame the engine sent, in order. Assert against this in tests.
    public private(set) var writes: [Write] = []
    public var maxWriteLength: Int

    public init(maxWriteLength: Int = 512) {
        self.maxWriteLength = maxWriteLength
    }

    public func sendFrame(_ frame: [UInt8], acknowledged: Bool) {
        writes.append(Write(frame: frame, acknowledged: acknowledged))
    }

    /// Convenience for assertions: the count of acknowledged (`.withResponse`) writes. The whole
    /// point of the fast algorithm is that per-chunk acks are UNacknowledged, so in a healthy
    /// offload this stays at 1 (just the kickoff) regardless of how many chunks streamed.
    public var acknowledgedWriteCount: Int {
        writes.filter { $0.acknowledged }.count
    }
}
