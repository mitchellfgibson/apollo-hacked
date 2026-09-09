import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class RespRateAnalyzerTests: XCTestCase {

    /// Wrap a flat 24 Hz waveform into per-second v26-style records starting at `t0`.
    private func seconds(_ wave: [Int], t0: Int = 1_700_000_000) -> [PPGWaveformSample] {
        let usable = wave.count - wave.count % 24
        return stride(from: 0, to: usable, by: 24).enumerated().map { idx, off in
            PPGWaveformSample(ts: t0 + idx, samples: Array(wave[off..<off + 24]))
        }
    }

    func testRecoversKnownRespRates() {
        for rate in [12.0, 16.0] {
            let wave = synthPPGWaveform(seconds: 300, hrBpm: 70, respPerMin: rate, amDepth: 0.6)
            let r = RespRateAnalyzer.analyze(seconds(wave))
            XCTAssertNotNil(r.breathsPerMin, "no resp rate at \(rate)/min")
            XCTAssertEqual(r.breathsPerMin ?? -1, rate, accuracy: 1.5, "resp rate off at \(rate)/min")
            XCTAssertGreaterThanOrEqual(r.nWindows, RespRateAnalyzer.minValidWindows)
        }
    }

    func testTooLittleDataReturnsNil() {
        // 90 s → at most 2 windows, below minValidWindows.
        let wave = synthPPGWaveform(seconds: 90, hrBpm: 70, respPerMin: 12, amDepth: 0.6)
        let r = RespRateAnalyzer.analyze(seconds(wave))
        XCTAssertNil(r.breathsPerMin)
    }

    func testUnmodulatedPulseReturnsNil() {
        // No AM → flat beat-amplitude envelope → no respiratory peak to find.
        let wave = synthPPGWaveform(seconds: 300, hrBpm: 70)
        let r = RespRateAnalyzer.analyze(seconds(wave))
        XCTAssertNil(r.breathsPerMin)
    }

    func testGapDoesNotSinkTheNight() {
        // A 10 s gap mid-recording: windows overlapping it are rejected by the gap check,
        // the rest still recover the rate.
        var recs = seconds(synthPPGWaveform(seconds: 300, hrBpm: 70, respPerMin: 14, amDepth: 0.6))
        recs.removeAll { (1_700_000_100..<1_700_000_110).contains($0.ts) }
        let r = RespRateAnalyzer.analyze(recs)
        XCTAssertNotNil(r.breathsPerMin)
        XCTAssertEqual(r.breathsPerMin ?? -1, 14, accuracy: 1.5)
    }

    // MARK: - analyzeDay integration

    /// Still, low-HR night ending 06:00 local on `day` (mirrors AnalyticsEngineTests.night),
    /// plus matching v26 PPG waveforms amplitude-modulated at 12 breaths/min.
    func testAnalyzeDayFillsRespRateFromPPG() {
        let day = "2021-06-15"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        let dayMidnight = Int(fmt.date(from: day)!.timeIntervalSince1970)
        let end = dayMidnight + 6 * 3600
        let start = end - 7 * 3600

        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var grav: [GravitySample] = []
        var toggle = false
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 50))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            if t % 2 == 0 {
                rr.append(RRInterval(ts: t, rrMs: toggle ? 1205 : 1195))
                toggle.toggle()
            }
        }
        let ppg = seconds(synthPPGWaveform(seconds: 7 * 3600, hrBpm: 50,
                                           respPerMin: 12, amDepth: 0.6), t0: start)

        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: hr, rr: rr, gravity: grav, ppg: ppg,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"))

        XCTAssertNotNil(result.daily.respRateBpm, "respRateBpm should be filled from v26 PPG")
        XCTAssertEqual(result.daily.respRateBpm ?? -1, 12, accuracy: 1.5)
    }

    func testAnalyzeDayWithoutPPGLeavesRespRateNil() {
        let day = "2021-06-15"
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        let dayMidnight = Int(fmt.date(from: day)!.timeIntervalSince1970)
        let end = dayMidnight + 6 * 3600
        let start = end - 7 * 3600
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        for t in start..<end {
            hr.append(HRSample(ts: t, bpm: 50))
            grav.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
        }
        let result = AnalyticsEngine.analyzeDay(
            day: day, hr: hr, gravity: grav,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"))
        XCTAssertNil(result.daily.respRateBpm)
    }
}
