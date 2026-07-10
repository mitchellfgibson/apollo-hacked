import XCTest
@testable import WhoopProtocol

/// Hardware-free tests for the FAST offload algorithm in `OffloadEngine`, driven entirely by
/// `MockTransport` + real metadata frames built with `frameFromPayload` (the same fixture approach
/// as `HistoricalMetaTests`). These pin the two properties the speedup must never break:
///
///   1. THROUGHPUT: per-chunk acks are UNacknowledged (`.withoutResponse`) and are emitted BEFORE
///      persistence, so the strap is never stalled waiting on a DB write or a BLE round-trip. The
///      only acknowledged write in a whole session is the single SEND_HISTORICAL kickoff.
///   2. SAFE-TRIM: `durableTrim` (the resume cursor) only advances after the caller confirms a chunk
///      is on disk. A crash after ack-but-before-persist safely re-pulls that chunk next session.
///
/// Everything runs on the MainActor (the engine's isolation) with no strap and no CoreBluetooth.
@MainActor
final class OffloadEngineTests: XCTestCase {

    // MARK: - Frame fixture builders (verified layout — see HistoricalMetaTests)

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// METADATA cmd=1 = HISTORY_START.
    private func startFrame() -> [UInt8] {
        frameFromPayload([], type: 49, seq: 0, cmd: 1)
    }
    /// METADATA cmd=2 = HISTORY_END with the 14-byte `<LHLL>` payload carrying unix + trim.
    /// Payload[10..14] = trim lands at frame[17..21], so `OffloadEngine.endData` (frame[17..25])
    /// captures the trim as its first u32 — matching the real high-freq ack form.
    private func endFrame(unix: UInt32 = 1_700_000_000, trim: UInt32, unk: UInt32 = 0xDEAD) -> [UInt8] {
        let payload: [UInt8] = le32(unix) + le16(0) + le32(unk) + le32(trim)
        return frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
    }
    /// METADATA cmd=3 = HISTORY_COMPLETE.
    private func completeFrame() -> [UInt8] {
        frameFromPayload([], type: 49, seq: 0, cmd: 3)
    }
    /// A type-47 HISTORICAL_DATA record (the payload frames between START and END).
    private func recordFrame(_ tag: UInt8) -> [UInt8] {
        frameFromPayload([tag, tag, tag, tag], type: 47, seq: 0, cmd: 0)
    }

    /// Build an engine wired to a mock transport. `makeAckFrame` / `makeKickoffFrame` produce real
    /// frames via the same builders the production BLEManager would use, so writes are on-wire valid.
    private func makeEngine() -> (OffloadEngine, MockTransport) {
        let transport = MockTransport()
        let engine = OffloadEngine(
            transport: transport,
            makeKickoffFrame: { frameFromPayload([0x00], type: 35, seq: 0, cmd: 22) },      // SEND_HISTORICAL_DATA
            makeAckFrame: { endData in frameFromPayload([0x01] + endData, type: 35, seq: 0, cmd: 23) } // HISTORICAL_DATA_RESULT
        )
        return (engine, transport)
    }

    // MARK: - Kickoff

    func testBeginSendsAcknowledgedKickoff() {
        let (engine, transport) = makeEngine()
        engine.begin()
        XCTAssertTrue(engine.isOffloading)
        XCTAssertEqual(transport.writes.count, 1)
        // The ONE place a confirmed write is correct: opening the session on a settled link.
        XCTAssertTrue(transport.writes[0].acknowledged)
    }

    // MARK: - THROUGHPUT: per-chunk ack is unacknowledged and fires before persistence

    func testChunkAckIsUnacknowledgedAndImmediate() {
        let (engine, transport) = makeEngine()
        var readyChunks: [(frames: [[UInt8]], trim: UInt32)] = []
        engine.onChunkReady = { frames, trim in readyChunks.append((frames, trim)) }

        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(recordFrame(1))
        engine.ingest(recordFrame(2))
        engine.ingest(endFrame(trim: 100))

        // The chunk was handed to the caller for persistence...
        XCTAssertEqual(readyChunks.count, 1)
        XCTAssertEqual(readyChunks[0].trim, 100)
        XCTAssertEqual(readyChunks[0].frames.count, 2)          // the two records, START/END excluded
        // ...and the ack was already emitted, UNacknowledged (no BLE round-trip, no wait on the DB).
        XCTAssertEqual(transport.writes.count, 2)               // kickoff + this ack
        XCTAssertFalse(transport.writes[1].acknowledged)
        XCTAssertEqual(engine.ackedTrim, 100)
    }

    func testManyChunksStreamWithoutASingleExtraAcknowledgedWrite() {
        let (engine, transport) = makeEngine()
        engine.onChunkReady = { _, _ in }                      // caller persists off-path

        engine.begin()
        engine.ingest(startFrame())
        // The watch's fast transfer mode: ONE start, then repeated END-closed chunks.
        for i in 1...50 {
            engine.ingest(recordFrame(UInt8(i & 0xFF)))
            engine.ingest(endFrame(trim: UInt32(i)))
        }
        // The whole point: 50 chunks streamed, but still exactly ONE acknowledged write (the kickoff).
        // The legacy loop would have paid 50 blocking round-trips here.
        XCTAssertEqual(transport.acknowledgedWriteCount, 1)
        XCTAssertEqual(engine.ackedTrim, 50)
    }

    // MARK: - SAFE-TRIM: durable cursor lags the acked cursor until the caller confirms

    func testDurableTrimDoesNotAdvanceUntilConfirmed() {
        let (engine, _) = makeEngine()
        var pending: [UInt32] = []
        engine.onChunkReady = { _, trim in pending.append(trim) }  // caller has NOT persisted yet

        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(recordFrame(1))
        engine.ingest(endFrame(trim: 100))
        engine.ingest(recordFrame(2))
        engine.ingest(endFrame(trim: 200))

        // Strap was acked up to 200 (kept streaming), but nothing is durable yet.
        XCTAssertEqual(engine.ackedTrim, 200)
        XCTAssertNil(engine.durableTrim)

        // Caller finishes persisting the first chunk only.
        engine.confirmDurable(trim: 100)
        XCTAssertEqual(engine.durableTrim, 100)                 // safe resume point = 100, NOT 200
        // Second chunk still in flight → a crash now safely re-pulls trim>100 next session.
        engine.confirmDurable(trim: 200)
        XCTAssertEqual(engine.durableTrim, 200)
    }

    func testDurableTrimOnlyMovesForward() {
        let (engine, _) = makeEngine()
        engine.onChunkReady = { _, _ in }
        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(endFrame(trim: 500))
        engine.confirmDurable(trim: 500)
        // A stale/out-of-order confirm must never move the safe cursor backward.
        engine.confirmDurable(trim: 300)
        XCTAssertEqual(engine.durableTrim, 500)
    }

    // MARK: - COMPLETE reports the SAFE (durable) cursor, not the acked one

    func testCompleteReportsDurableCursor() {
        let (engine, _) = makeEngine()
        engine.onChunkReady = { _, _ in }
        var completedWith: UInt32?? = nil
        engine.onComplete = { completedWith = $0 }

        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(endFrame(trim: 100))
        engine.confirmDurable(trim: 100)
        engine.ingest(completeFrame())

        XCTAssertFalse(engine.isOffloading)
        XCTAssertEqual(completedWith, .some(.some(100)))
    }

    // MARK: - Abort advances nothing (watchdog / stalled link)

    func testAbortLeavesDurableCursorUntouched() {
        let (engine, _) = makeEngine()
        engine.onChunkReady = { _, _ in }
        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(endFrame(trim: 100))       // acked but not confirmed
        engine.abort()
        XCTAssertFalse(engine.isOffloading)
        XCTAssertNil(engine.durableTrim)          // next session safely resumes from before 100
    }

    // MARK: - Empty END still advances the trim (that's how the offload progresses)

    func testEmptyEndAcksWithNoChunkFrames() {
        let (engine, transport) = makeEngine()
        var readyChunks: [(frames: [[UInt8]], trim: UInt32)] = []
        engine.onChunkReady = { frames, trim in readyChunks.append((frames, trim)) }
        engine.begin()
        engine.ingest(startFrame())
        engine.ingest(endFrame(trim: 100))        // END with zero accumulated records
        XCTAssertEqual(readyChunks.count, 1)
        XCTAssertTrue(readyChunks[0].frames.isEmpty)
        XCTAssertFalse(transport.writes[1].acknowledged)  // still acked (unacknowledged), advancing trim
        XCTAssertEqual(engine.ackedTrim, 100)
    }
}
