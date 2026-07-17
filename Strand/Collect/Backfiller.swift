import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - BackfillStoreWriting protocol

/// The async subset the Backfiller needs. Plain async protocol (not @MainActor) so both the
/// real WhoopStore actor and a @MainActor SpyBackfillStore in tests can satisfy it.
protocol BackfillStoreWriting: AnyObject {
    @discardableResult
    func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws
    func setCursor(_ name: String, _ value: Int) async throws
    func cursor(_ name: String) async throws -> Int?
}

extension WhoopStore: BackfillStoreWriting {}

// MARK: - Backfiller

/// Historical-offload state machine (idle / backfilling).
///
/// Per-chunk local safe-trim invariant:
///   decode known → await insert (decoded durable) →
///   await enqueueRawBatch (raw durable) →
///   await setCursor(strap_trim) →
///   ackTrim (link-layer confirmed ack to strap)
///
/// A chunk is forgotten only after decoded AND raw are both locally durable AND the ack
/// (.withResponse) is link-layer confirmed. Never waits on the server.
@MainActor
final class Backfiller {
    typealias Extractor = ([ParsedFrame], Int, Int) -> Streams

    private let store: BackfillStoreWriting
    private let deviceId: String
    /// Confirms one HISTORY_END chunk to the strap. Carries both the trim cursor (= first u32
    /// of end_data, used for the `strap_trim` cursor) and the 8-byte `end_data` (= the raw
    /// HISTORY_END metadata.data[10:18]) that the high-freq-sync ack form requires verbatim.
    private let ackTrim: (_ trim: UInt32, _ endData: [UInt8]) -> Void
    private let extract: Extractor
    /// Research toggle. When false (DEFAULT) no raw frames are persisted — the chunk's
    /// decoded streams are still durable and the trim is still acked (decoded is the product of
    /// record). Injected for tests; backed by UserDefaults in the production init site.
    private let enableRawCapture: Bool

    /// The clock reference set by BLEManager when GET_CLOCK confirms (required for decoding).
    var clockRef: ClockRef?

    /// Device family — selects the frame-parse offsets. WHOOP 5/MG (puffin) frames put the packet
    /// type + fields 4 bytes later than WHOOP 4, so parsing must be family-aware or every historical
    /// record decodes to garbage (or nothing).
    var family: DeviceFamily = .whoop4

    /// True while a historical offload session is active.
    private(set) var isBackfilling = false

    /// Buffered data frames for the current open chunk (between START and END).
    private var chunk: [[UInt8]] = []
    /// Whether a START has been received and we're accumulating a chunk.
    private var chunkOpen = false

    init(store: BackfillStoreWriting,
         deviceId: String,
         ackTrim: @escaping (_ trim: UInt32, _ endData: [UInt8]) -> Void,
         enableRawCapture: Bool = false,
         extract: @escaping Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2) }) {
        self.store = store
        self.deviceId = deviceId
        self.ackTrim = ackTrim
        self.enableRawCapture = enableRawCapture
        self.extract = extract
    }

    /// Called by BLEManager when the strap signals a historical offload is beginning.
    /// chunkOpen starts TRUE: the high-freq-sync biometric replay streams records immediately and
    /// sends one HISTORY_START then repeated HISTORY_ENDs, so we must accumulate from the outset.
    func begin() {
        isBackfilling = true
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = true
    }

    /// Feed one raw BLE frame into the state machine. May trigger async store operations.
    func ingest(_ frame: [UInt8]) async {
        switch classifyHistoricalMeta(parseFrame(frame)) {
        case .start:
            isBackfilling = true
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = true
        case .end(let unix, let trim):
            await finishChunk(unix: unix, trim: trim, endFrame: frame)
        case .complete:
            isBackfilling = false
            chunk.removeAll(keepingCapacity: true)
            chunkOpen = false
        case .other:
            if chunkOpen { chunk.append(frame) }
        }
    }

    /// The 8-byte `end_data` the high-freq-sync ack requires: metadata.data[10:18].
    /// metadata.data begins at frame[7] (after [type,seq,cmd]), so end_data = frame[17:25].
    /// trim cursor = the first u32 of end_data (data[10:14]). Returns nil if the frame is too
    /// short to contain the field (shouldn't happen for a real HISTORY_END, which is >=14 data
    /// bytes, but guards against a malformed frame).
    static func endData(from frame: [UInt8]) -> [UInt8]? {
        guard frame.count >= 25 else { return nil }
        return Array(frame[17..<25])
    }

    /// Commit one HISTORY_END chunk: (persist decoded → enqueueRaw when present) → setCursor → ackTrim.
    /// Early-returns on any throw to preserve the safe-trim invariant.
    ///
    /// CRITICAL: high-freq-sync sends ONE HISTORY_START then REPEATED HISTORY_ENDs (a chunk-close
    /// every ~50 records). So we must ack EVERY end and keep accumulating afterwards — NOT close
    /// the chunk after the first. We snapshot+clear the accumulated frames but leave `chunkOpen`
    /// TRUE so the records following this END become the next chunk. An END with no accumulated
    /// records is still acked (it advances the strap's trim) — that's how the offload progresses.
    /// `endFrame` carries the 8-byte `end_data` the ack requires.
    private func finishChunk(unix: UInt32, trim: UInt32, endFrame: [UInt8]) async {
        guard let endData = Backfiller.endData(from: endFrame) else { return }

        let frames = chunk
        chunk.removeAll(keepingCapacity: true)   // next records accumulate into the next chunk

        if !frames.isEmpty {
            // type-47 HISTORICAL_DATA carries its OWN real-unix timestamp — extractHistoricalStreams
            // ignores the clock offset for it — so the historical offload does NOT need GET_CLOCK.
            // If the (device,wall) correlation isn't established yet (e.g. GET_CLOCK silent), fall back
            // to an identity ref (device==wall==now): the offset math becomes a no-op, type-47 still
            // decodes to correct wall time, and we can persist + ack + upload. The correlation is only
            // truly required to map REALTIME (type-40/43) device-epoch timestamps, never in a hist chunk.
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()
            let parsed = frames.map { parseFrame($0) }
            let decoded = extract(parsed, ref.device, ref.wall)
            do { try await store.insert(decoded, deviceId: deviceId) } catch { return }

            // RAW: only persisted when the research toggle is ON. Default OFF → decoded-only; the
            // chunk is still durably committed (decoded) so the trim is safe to advance + ack.
            if enableRawCapture {
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch { return }
            }
        }
        do { try await store.setCursor("strap_trim", Int(trim)) } catch { return }

        ackTrim(trim, endData)
    }

    /// Called when a backfill watchdog timer fires (strap went silent mid-offload).
    /// Clears state without acking — the chunk was never durably committed.
    func timeoutFired() {
        isBackfilling = false
        chunk.removeAll(keepingCapacity: true)
        chunkOpen = false
    }

    // MARK: - OffloadEngine integration (fast-path persistence)

    /// Durably persist one chunk's frames WITHOUT acking — used by the `OffloadEngine` fast path,
    /// where the ack has already been sent (unconfirmed) the moment the chunk was snapshotted, and
    /// this runs off the critical path. Returns `true` only when the chunk is fully durable (decoded
    /// inserted, raw enqueued when enabled, and the `strap_trim` cursor advanced) — the caller then
    /// calls `OffloadEngine.confirmDurable(trim:)` to move the safe resume cursor. Returns `false`
    /// on any store error so the durable cursor stays behind and the next session re-pulls the chunk.
    ///
    /// This is the SAME decode→insert→enqueueRaw→setCursor sequence as `finishChunk`, minus the ack
    /// (the engine owns acking now) — so the safe-trim invariant is preserved exactly.
    @discardableResult
    func persistChunk(frames: [[UInt8]], trim: UInt32) async -> Bool {
        if !frames.isEmpty {
            let ref = clockRef ?? { let now = Int(Date().timeIntervalSince1970); return ClockRef(device: now, wall: now) }()

            // THROUGHPUT: on this firmware ~96% of the offloaded bytes are v20/v21 type-47 records —
            // the bulk 100 Hz raw optical/PPG waveforms (1244–2140 B each). They carry NO named field
            // our `extract` understands (HR/gravity/skin-temp/rr all live in the tiny v18 summary), so
            // fully `parseFrame`-ing them was pure wasted CPU that starved the v18 summaries behind it.
            // Split by version (a cheap header read, no full parse): fully decode+insert ONLY the
            // summary frames (v18 and everything that isn't a known raw-waveform version); the raw
            // v20/v21 frames are still stored verbatim below (nothing lost — they're preserved on disk
            // for the future PPG-decode project), just not decoded here.
            let summaryFrames = frames.filter { !Self.isRawWaveformFrame($0, family: family) }
            if !summaryFrames.isEmpty {
                let parsed = summaryFrames.map { parseFrame($0, family: family) }
                let decoded = extract(parsed, ref.device, ref.wall)
                do { try await store.insert(decoded, deviceId: deviceId) } catch { return false }
            }
            if enableRawCapture {
                // Store ALL frames raw (including v20/v21) so the 100 Hz PPG is preserved for later.
                let meta = RawBatchMeta(
                    batchId: "hist-\(deviceId)-\(trim)",
                    deviceId: deviceId,
                    clockRef: ref,
                    capturedAt: Int(Date().timeIntervalSince1970),
                    startTs: ref.wall,
                    endTs: ref.wall,
                    frameCount: frames.count,
                    byteSize: frames.reduce(0) { $0 + $1.count })
                do { try await store.enqueueRawBatch(meta, frames: frames) } catch { return false }
            }
        }
        do { try await store.setCursor("strap_trim", Int(trim)) } catch { return false }
        return true
    }

    /// True for a type-47 HISTORICAL_DATA frame whose layout version is a bulk raw-waveform record
    /// (v20/v21 — the 100 Hz optical channels), which `extract` produces no usable named fields from.
    /// Cheap header-only check: packet type at frame[8] (puffin) / frame[4] (whoop4), version at the
    /// following byte. Anything else (v18 summary, v26 burst, non-type-47) returns false so it's
    /// still fully decoded.
    static func isRawWaveformFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        let typeOffset: Int
        switch family {
        case .whoop5: typeOffset = 8
        case .whoop4: typeOffset = 4
        }
        let verOffset = typeOffset + 1
        guard frame.count > verOffset else { return false }
        guard frame[typeOffset] == 47 else { return false }   // only HISTORICAL_DATA has these versions
        return frame[verOffset] == 20 || frame[verOffset] == 21
    }
}
