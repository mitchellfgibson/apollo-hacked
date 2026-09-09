import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Validation against the REAL Sep 8→9 night pulled off the phone (HR+R-R live, gravity barely
/// offloaded — 708 samples in an 11-min window). Fixtures are CSVs exported from the device DB.
/// Skips cleanly when the fixtures are absent (CI / other machines), so it never blocks the suite.
final class HRFallbackRealNightTests: XCTestCase {

    private var fixtureDir: String? {
        let p = "/private/tmp/claude-501/-Users-mitchellgibson-noop--noop/8a9afb4e-d545-4bbd-a9b1-d7ce7cbf7951/scratchpad/phonedb"
        return FileManager.default.fileExists(atPath: p + "/night_hr.csv") ? p : nil
    }

    private func loadCSV(_ path: String) -> [[String]] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map { $0.split(separator: ",").map(String.init) }
    }

    func testRealLiveNightYieldsSessionWithRestingHRandHRV() throws {
        guard let dir = fixtureDir else {
            throw XCTSkip("real-night fixtures not present on this machine")
        }
        let hr = loadCSV(dir + "/night_hr.csv").compactMap { r -> HRSample? in
            guard r.count == 2, let ts = Int(r[0]), let bpm = Int(r[1]) else { return nil }
            return HRSample(ts: ts, bpm: bpm)
        }
        let rr = loadCSV(dir + "/night_rr.csv").compactMap { r -> RRInterval? in
            guard r.count == 2, let ts = Int(r[0]), let ms = Int(r[1]) else { return nil }
            return RRInterval(ts: ts, rrMs: ms)
        }
        let grav = loadCSV(dir + "/night_grav.csv").compactMap { r -> GravitySample? in
            guard r.count == 4, let ts = Int(r[0]), let x = Double(r[1]),
                  let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return GravitySample(ts: ts, x: x, y: y, z: z)
        }
        XCTAssertGreaterThan(hr.count, 5000, "expected the full night's HR")

        // The bug: gravity does NOT cover the HR window, so the gravity spine finds nothing.
        XCTAssertFalse(SleepStager.gravityCoversHRWindow(grav.sorted { $0.ts < $1.ts },
                                                         hr.sorted { $0.ts < $1.ts }),
                       "this night's gravity should be too sparse for the gravity spine")

        // The fix: HR-quiescence fallback detects the night and yields resting HR + HRV.
        let sessions = SleepStager.detectSleep(hr: hr, rr: rr, resp: [], gravity: grav)
        XCTAssertFalse(sessions.isEmpty, "HR fallback must detect the live night")

        let longest = sessions.max { ($0.end - $0.start) < ($1.end - $1.start) }!
        let minutes = Double(longest.end - longest.start) / 60.0
        XCTAssertGreaterThan(minutes, 180, "main sleep span should be multi-hour")
        XCTAssertNotNil(longest.restingHR, "resting HR must be computed from HR alone")
        XCTAssertNotNil(longest.avgHRV, "HRV must be computed from R-R alone")
        // Sanity ranges for an overnight adult sleep.
        if let rhr = longest.restingHR { XCTAssertTrue((35...75).contains(rhr), "RHR \(rhr) implausible") }
        if let hrv = longest.avgHRV { XCTAssertTrue((10...250).contains(hrv), "HRV \(hrv) implausible") }
        XCTAssertTrue((0.4...0.97).contains(longest.efficiency), "efficiency \(longest.efficiency) off")

        print("REAL NIGHT → \(sessions.count) session(s); main \(Int(minutes))min "
              + "RHR=\(longest.restingHR.map(String.init) ?? "nil") "
              + "HRV=\(longest.avgHRV.map { String(format: "%.1f", $0) } ?? "nil") "
              + "eff=\(String(format: "%.2f", longest.efficiency))")
    }
}
