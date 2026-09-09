import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Deterministic (fixture-free) tests for the HR-quiescence sleep fallback — the path that lets a
/// live night (HR + R-R present, gravity not yet offloaded) still yield resting HR / HRV / recovery.
final class HRFallbackSleepTests: XCTestCase {

    /// Build a synthetic night: `awakeMin` of elevated HR, then `sleepMin` of low HR, then waking.
    /// R-R is generated to match (60000/bpm) with a little beat-to-beat jitter so HRV is non-trivial.
    private func syntheticNight(start: Int, awakeMin: Int, sleepMin: Int,
                                awakeBpm: Int, sleepBpm: Int)
        -> (hr: [HRSample], rr: [RRInterval]) {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var t = start
        func emit(_ bpm: Int, minutes: Int) {
            for s in 0..<(minutes * 60) {
                let jitter = (s % 5) - 2                    // ±2 bpm ripple
                let b = max(30, bpm + jitter)
                hr.append(HRSample(ts: t, bpm: b))
                rr.append(RRInterval(ts: t, rrMs: 60000 / b))
                t += 1
            }
        }
        emit(awakeBpm, minutes: awakeMin)
        emit(sleepBpm, minutes: sleepMin)
        emit(awakeBpm, minutes: 20)
        return (hr, rr)
    }

    func testFallbackDetectsSleepFromHROnly() {
        let start = 1_800_000_000
        let (hr, rr) = syntheticNight(start: start, awakeMin: 30, sleepMin: 300,
                                      awakeBpm: 78, sleepBpm: 50)
        // No gravity at all — the exact live-night condition.
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: [], gravity: [])
        XCTAssertEqual(sessions.count, 1, "should detect the single low-HR span as sleep")
        let s = sessions[0]
        XCTAssertGreaterThan(Double(s.end - s.start) / 60.0, 240, "sleep span should be ~5h")
        XCTAssertNotNil(s.restingHR)
        XCTAssertNotNil(s.avgHRV)
        if let rhr = s.restingHR { XCTAssertLessThanOrEqual(rhr, 55, "RHR should track the sleep floor") }
    }

    func testGravityAbsentButHRTooSparseYieldsNothing() {
        // Under the min-sample floor → no fabricated session.
        let hr = (0..<10).map { HRSample(ts: 1_800_000_000 + $0, bpm: 50) }
        XCTAssertTrue(SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: []).isEmpty)
    }

    func testAllEmptyYieldsNothing() {
        XCTAssertTrue(SleepStager.detectSleep(hr: [], rr: [], resp: [], gravity: []).isEmpty)
    }

    func testGravityPathStillPreferredWhenGravityCoversWindow() {
        // A still night with dense gravity + matching low HR: the gravity spine should own it,
        // and gravityCoversHRWindow must report true (fallback NOT taken).
        let start = 1_800_000_000
        var grav: [GravitySample] = []
        var hr: [HRSample] = []
        for m in 0..<(300 * 60) {           // 5h, 1 Hz gravity + HR, essentially motionless
            grav.append(GravitySample(ts: start + m, x: 0.10, y: 0.20, z: 0.97))
            hr.append(HRSample(ts: start + m, bpm: 50))
        }
        XCTAssertTrue(SleepStager.gravityCoversHRWindow(grav, hr))
        XCTAssertFalse(SleepStager.detectSleep(hr: hr, rr: [], resp: [], gravity: grav).isEmpty)
    }

    func testSparseGravityFallsBackToHR() {
        // HR spans 6h; gravity only covers the last 10 min → below the coverage floor → HR fallback.
        let start = 1_800_000_000
        let (hr, rr) = syntheticNight(start: start, awakeMin: 20, sleepMin: 300,
                                      awakeBpm: 80, sleepBpm: 48)
        let hrEnd = hr.last!.ts
        let grav = (0..<600).map { GravitySample(ts: hrEnd - 600 + $0, x: 0.1, y: 0.2, z: 0.97) }
        XCTAssertFalse(SleepStager.gravityCoversHRWindow(grav, hr), "10 min gravity over 6h HR is sparse")
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: [], gravity: grav)
        XCTAssertEqual(sessions.count, 1, "should fall back to HR and detect the night")
        XCTAssertNotNil(sessions[0].avgHRV)
    }
}
