import XCTest
@testable import Strand

/// Pins the #617 bond-loop detection: a WHOOP 4 strap bonds successfully, then the encrypted link drops
/// ~1s later with a connection timeout, the auto-rescan reconnects, it bonds again, and dies again — an
/// endless bond→timeout loop on macOS/iOS. PostBondTimeoutLoopDetector watches for CONSECUTIVE
/// bond-then-quick-timeout cycles and, after the threshold, tells BLEManager to surface the existing
/// re-pair guide instead of looping silently. Pure value type → no CoreBluetooth seam needed.
final class PostBondTimeoutLoopDetectorTests: XCTestCase {

    // Two consecutive bond-then-quick-timeout cycles trip the loop; the trip is reported exactly once.
    func testTripsAfterTwoConsecutiveBondTimeouts() {
        var d = PostBondTimeoutLoopDetector()   // default tripThreshold=2, window=8s
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true),
                       "one bond-then-timeout is noise, not yet a trip")
        XCTAssertFalse(d.tripped)
        XCTAssertTrue(d.connectionEnded(wasBonded: true, secondsSinceBond: 1.2, timedOut: true),
                      "second consecutive bond-then-timeout trips the loop")
        XCTAssertTrue(d.tripped)
        // Already tripped → no second "freshly tripped" signal (caller surfaces the guide only once).
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 0.9, timedOut: true))
        XCTAssertTrue(d.tripped)
    }

    // A single quick post-bond drop must never trip — links die for benign reasons. Below threshold stays untripped.
    func testSingleDropDoesNotTrip() {
        var d = PostBondTimeoutLoopDetector()
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertFalse(d.tripped)
        XCTAssertEqual(d.consecutiveBondTimeouts, 1)
    }

    // A drop that lands LONG after bonding is a healthy session that flapped later, not the bond loop.
    // It must break the streak rather than count toward a trip (don't mis-trip a healthy link).
    func testTimeoutOutsideWindowBreaksStreak() {
        var d = PostBondTimeoutLoopDetector(tripThreshold: 2, quickTimeoutWindow: 8)
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 2, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 1)
        // 90s after bonding: the link clearly survived the bond — this drop is unrelated to the loop.
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 90, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 0, "a late drop resets the bond-timeout streak")
        XCTAssertFalse(d.tripped)
    }

    // A non-timeout close (timedOut:false — intentional disconnect, bond reset, clean close) must never
    // count toward the streak. The bond-loop's signature is specifically a CONNECTION TIMEOUT.
    func testNonTimeoutCloseDoesNotCount() {
        var d = PostBondTimeoutLoopDetector()
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: false))
        XCTAssertEqual(d.consecutiveBondTimeouts, 0, "a clean (non-timeout) close resets suspicion")
        // ...and now it takes two fresh bond-timeouts again to trip.
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertTrue(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertTrue(d.tripped)
    }

    // A drop where the link never bonded (wasBonded:false — e.g. it failed before the bond) can't be the
    // bond loop and must reset the streak.
    func testUnbondedDropResetsStreak() {
        var d = PostBondTimeoutLoopDetector()
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 1)
        XCTAssertFalse(d.connectionEnded(wasBonded: false, secondsSinceBond: nil, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 0)
    }

    // A timeout with no bond timestamp (secondsSinceBond == nil) can't be classified as quick → no count.
    func testNilSinceBondDoesNotCount() {
        var d = PostBondTimeoutLoopDetector()
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: nil, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 0)
        XCTAssertFalse(d.tripped)
    }

    // The boundary value (exactly at the window) still counts — a drop right at the edge is part of the loop.
    func testTimeoutAtWindowBoundaryCounts() {
        var d = PostBondTimeoutLoopDetector(tripThreshold: 2, quickTimeoutWindow: 8)
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 8, timedOut: true))
        XCTAssertEqual(d.consecutiveBondTimeouts, 1, "exactly at the window boundary still counts")
    }

    // reset() clears everything — used on a clean user-initiated disconnect, so a transient bond hiccup
    // isn't a permanent flag.
    func testResetClearsState() {
        var d = PostBondTimeoutLoopDetector()
        _ = d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true)
        _ = d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true)
        XCTAssertTrue(d.tripped)
        d.reset()
        XCTAssertFalse(d.tripped)
        XCTAssertEqual(d.consecutiveBondTimeouts, 0)
        // After reset it takes the full threshold again to re-trip.
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertFalse(d.tripped)
    }

    // A custom higher threshold (e.g. 3) requires that many consecutive cycles.
    func testCustomThreshold() {
        var d = PostBondTimeoutLoopDetector(tripThreshold: 3, quickTimeoutWindow: 8)
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertFalse(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertFalse(d.tripped)
        XCTAssertTrue(d.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        XCTAssertTrue(d.tripped)
    }
}
