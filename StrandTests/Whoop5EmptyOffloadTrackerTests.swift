import XCTest
@testable import Strand

/// Pins the #580 fix: a connected WHOOP 5/MG whose firmware acks SEND_HISTORICAL_DATA but emits ZERO
/// type-0x2F offload frames. Live HR streams fine over 0x2A37, but every offload times out — and the old
/// code surfaced the WHOOP-4 "strap went quiet" sync error and let the 120s liveness watchdog bounce the
/// (healthy) link every ~2 min. Whoop5EmptyOffloadTracker counts CONSECUTIVE empty offloads so a sustained
/// empty streak reads as "history sync experimental on 5.0" (not a sync error) and the bounce loop backs
/// off; any offload that banks real records clears the streak. Pure value type → no CoreBluetooth seam.
final class Whoop5EmptyOffloadTrackerTests: XCTestCase {

    // One empty offload must NOT flip to experimental — the first offload after connect can race the
    // strap waking its flash, so a single empty cycle is noise.
    func testSingleEmptyOffloadStaysQuiet() {
        var t = Whoop5EmptyOffloadTracker()        // default threshold 2
        XCTAssertFalse(t.recordOffload(bankedRecords: false))
        XCTAssertFalse(t.historyEmpty)
        XCTAssertEqual(t.consecutiveEmpty, 1)
    }

    // Two CONSECUTIVE empty offloads = the firmware genuinely isn't serving history ⇒ go experimental.
    // The return is true exactly on the crossing call so the caller logs/surfaces once.
    func testTwoConsecutiveEmptyOffloadsGoExperimental() {
        var t = Whoop5EmptyOffloadTracker()
        XCTAssertFalse(t.recordOffload(bankedRecords: false))
        XCTAssertTrue(t.recordOffload(bankedRecords: false), "the crossing call reports true once")
        XCTAssertTrue(t.historyEmpty)
        XCTAssertEqual(t.consecutiveEmpty, 2)
    }

    // Once experimental, further empty offloads stay experimental but DON'T re-report the crossing (so the
    // honest note + bounce backoff don't re-log on every 60s timeout).
    func testStaysExperimentalWithoutRecrossing() {
        var t = Whoop5EmptyOffloadTracker()
        _ = t.recordOffload(bankedRecords: false)
        XCTAssertTrue(t.recordOffload(bankedRecords: false))
        XCTAssertFalse(t.recordOffload(bankedRecords: false), "already experimental — don't re-cross")
        XCTAssertTrue(t.historyEmpty)
        XCTAssertEqual(t.consecutiveEmpty, 3)
    }

    // A banking offload (real records handed over) clears the streak AND the experimental flag — the strap
    // started banking, so the home state must drop back to a normal sync immediately.
    func testBankingOffloadClearsExperimental() {
        var t = Whoop5EmptyOffloadTracker()
        _ = t.recordOffload(bankedRecords: false)
        XCTAssertTrue(t.recordOffload(bankedRecords: false))
        XCTAssertTrue(t.historyEmpty)
        XCTAssertFalse(t.recordOffload(bankedRecords: true), "a banking offload is never a crossing")
        XCTAssertFalse(t.historyEmpty)
        XCTAssertEqual(t.consecutiveEmpty, 0)
    }

    // After a banking offload clears the streak it takes the full threshold again to go experimental — a
    // strap that banks intermittently never sticks on the experimental note.
    func testRecoveryThenRequiresFullStreakAgain() {
        var t = Whoop5EmptyOffloadTracker()
        _ = t.recordOffload(bankedRecords: false)
        _ = t.recordOffload(bankedRecords: false)        // now experimental
        _ = t.recordOffload(bankedRecords: true)         // recovered
        XCTAssertFalse(t.recordOffload(bankedRecords: false))
        XCTAssertFalse(t.historyEmpty, "one empty after recovery isn't enough")
        XCTAssertTrue(t.recordOffload(bankedRecords: false))
        XCTAssertTrue(t.historyEmpty)
    }

    // reset() (a fresh connect / user-requested sync) clears everything so the next offload re-derives state.
    func testResetClearsState() {
        var t = Whoop5EmptyOffloadTracker()
        _ = t.recordOffload(bankedRecords: false)
        _ = t.recordOffload(bankedRecords: false)
        XCTAssertTrue(t.historyEmpty)
        t.reset()
        XCTAssertFalse(t.historyEmpty)
        XCTAssertEqual(t.consecutiveEmpty, 0)
    }

    // A custom (higher) threshold needs more empty cycles before flipping.
    func testCustomThreshold() {
        var t = Whoop5EmptyOffloadTracker(quietThreshold: 3)
        XCTAssertFalse(t.recordOffload(bankedRecords: false))
        XCTAssertFalse(t.recordOffload(bankedRecords: false))
        XCTAssertTrue(t.recordOffload(bankedRecords: false))
    }
}
