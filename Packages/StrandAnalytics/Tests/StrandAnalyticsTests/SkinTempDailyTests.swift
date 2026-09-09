import XCTest
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// Tier-3: nightly skin temperature flows from the in-sleep raw ADC samples into the day result.
final class SkinTempDailyTests: XCTestCase {

    private func day(_ s: String) -> (day: String, start: Int, end: Int) {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        let mid = Int(f.date(from: s)!.timeIntervalSince1970)
        let end = mid + 6 * 3600
        return (s, end - 7 * 3600, end)
    }

    /// A still, low-HR night (gravity spine) with skin-temp ADC at a known °C → nightlySkinTempC set.
    func testAnalyzeDayComputesNightlySkinTempC() {
        let d = day("2021-06-15")
        var hr: [HRSample] = []; var grav: [GravitySample] = []; var temp: [SkinTempSample] = []
        for t in d.start..<d.end {
            hr.append(HRSample(ts: t, bpm: 50))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            temp.append(SkinTempSample(ts: t, raw: 3350))   // 33.50 °C
        }
        let res = AnalyticsEngine.analyzeDay(
            day: d.day, hr: hr, gravity: grav, skinTemp: temp,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"))
        XCTAssertNotNil(res.nightlySkinTempC, "in-sleep temp should yield a nightly °C")
        XCTAssertEqual(res.nightlySkinTempC ?? -1, 33.5, accuracy: 0.2)
    }

    func testNoTempYieldsNilNightlyTemp() {
        let d = day("2021-06-15")
        var hr: [HRSample] = []; var grav: [GravitySample] = []
        for t in d.start..<d.end {
            hr.append(HRSample(ts: t, bpm: 50)); grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
        }
        let res = AnalyticsEngine.analyzeDay(
            day: d.day, hr: hr, gravity: grav,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"))
        XCTAssertNil(res.nightlySkinTempC)
    }

    func testDeviationHelperRewritesOnlyThatField() {
        let m = DailyMetric(day: "2021-06-15", totalSleepMin: 400, efficiency: 0.9, deepMin: 60,
                            remMin: 90, lightMin: 250, disturbances: 3, restingHr: 50, avgHrv: 65,
                            recovery: 70, strain: 10, exerciseCount: 1)
        let out = m.withSkinTempDevC(-0.4)
        XCTAssertEqual(out.skinTempDevC ?? 0, -0.4, accuracy: 1e-9)
        XCTAssertEqual(out.restingHr, 50)          // everything else preserved
        XCTAssertEqual(out.avgHrv ?? 0, 65, accuracy: 1e-9)
        XCTAssertEqual(out.totalSleepMin ?? 0, 400, accuracy: 1e-9)
    }
}
