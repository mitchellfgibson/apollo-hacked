import XCTest
@testable import StrandAnalytics

/// `SpotHrvReading` — the on-demand "take an HRV reading now" spot RMSSD path (#537).
///
/// Swift parity twin of `android/.../analytics/SpotHrvReadingTest.kt`. The headline guarantee these
/// tests pin is CONSISTENCY: the spot value uses the SAME RMSSD math as NOOP's nightly HRV
/// (`HRVAnalyzer.rmssdRaw`, Task Force 1996, sample (n-1) denominator), so a spot reading is comparable
/// to the overnight number, not a few percent off it. We assert the value against a hand-computed (n-1)
/// RMSSD on a known RR series, and against `HRVAnalyzer` directly.
final class SpotHrvReadingTests: XCTestCase {

    /// Textbook RMSSD with the Task Force (1996) SAMPLE denominator (n-1) — the reference NOOP uses.
    private func rmssdSampleDenom(_ rr: [Double]) -> Double {
        var sumSq = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            sumSq += d * d
        }
        return (sumSq / Double(rr.count - 1)).squareRoot()
    }

    /// A clean, in-range RR series long enough to clear minBeats, with small beat-to-beat variation.
    private func knownCleanSeries() -> [Int] {
        // 24 intervals around 850 ms (~70 bpm), alternating +/-20 ms so successive diffs are well-defined
        // and every value sits inside [300, 2000] ms so the range filter keeps them all.
        var out: [Int] = []
        let base = 850
        for i in 0..<24 {
            out.append(base + (i % 2 == 0 ? 20 : -20))
        }
        return out
    }

    func testSpotRmssdMatchesHandComputedSampleDenominator() {
        let rr = knownCleanSeries()
        let outcome = SpotHrvReading.compute(rr)
        guard case let .reading(rmssdMs, _, beats, _) = outcome else {
            return XCTFail("a clean 24-beat series must produce a reading, got \(outcome)")
        }

        // The series has no ectopics (alternating +/-20 around the median is within the 20% Malik gate),
        // so all 24 survive cleaning and the (n-1) RMSSD over them is the reference.
        let expected = rmssdSampleDenom(rr.map(Double.init))
        XCTAssertEqual(rmssdMs, expected, accuracy: 1e-9, "spot RMSSD must equal the (n-1) reference")
        XCTAssertEqual(beats, 24, "all 24 clean beats used")
    }

    func testSpotRmssdEqualsHrvAnalyzerNightlyMath() {
        // The spot path MUST agree with the canonical analyzer the nightly avgHrv is built on, beat for
        // beat — that is the whole consistency requirement of this lane.
        let rr = knownCleanSeries()
        let viaAnalyzer = HRVAnalyzer.analyze(rawRR: rr.map(Double.init)).rmssd
        XCTAssertNotNil(viaAnalyzer)
        guard case let .reading(viaSpot, _, _, _) = SpotHrvReading.compute(rr) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(viaAnalyzer!, viaSpot, accuracy: 1e-12)
    }

    func testUsesTaskForceSampleDenominator() {
        // RMSSD divides the summed squared successive diffs by the SAMPLE NN count minus one (n-1),
        // which for a contiguous clean series equals the number of diffs. The guard here is that the
        // spot path reproduces the Task Force form exactly (a from-scratch port that divided by a
        // different count would fail this), and that the same number flows through to the analyzer.
        let rr = knownCleanSeries().map(Double.init)
        var sumSq = 0.0
        for i in 1..<rr.count { let d = rr[i] - rr[i - 1]; sumSq += d * d }
        let taskForce = (sumSq / Double(rr.count - 1)).squareRoot() // divide by NN-1

        guard case let .reading(spot, _, _, _) = SpotHrvReading.compute(knownCleanSeries()) else {
            return XCTFail("expected a reading")
        }
        XCTAssertEqual(taskForce, spot, accuracy: 1e-9)
        XCTAssertEqual(rmssdSampleDenom(rr), spot, accuracy: 1e-9)
    }

    func testTooFewCleanBeatsIsHonestlyInsufficientNotFabricated() {
        // Only a handful of beats — below minBeats — must yield .insufficient, never a number.
        let outcome = SpotHrvReading.compute([850, 870, 840, 860, 855])
        guard case let .insufficient(clean, needed, _) = outcome else {
            return XCTFail("expected .insufficient, got \(outcome)")
        }
        XCTAssertEqual(needed, HRVAnalyzer.minBeats)
        XCTAssertTrue(clean < needed, "fewer clean beats than needed")
    }

    func testOutOfRangeIntervalsAreBoundsCheckedAway() {
        // Untrusted BLE input: garbage intervals (0, negative, absurdly large) must be filtered by the
        // analyzer's range gate, leaving too few clean beats -> .insufficient (no crash, no fabrication).
        let junk = [0, -5, 50_000, 999_999, 12]
        guard case .insufficient = SpotHrvReading.compute(junk) else {
            return XCTFail("expected .insufficient for junk input")
        }
    }

    func testEmptyInputIsInsufficient() {
        guard case let .insufficient(clean, _, _) = SpotHrvReading.compute([]) else {
            return XCTFail("expected .insufficient for empty input")
        }
        XCTAssertEqual(clean, 0)
    }

    func testSpotGateRefusesNoisyCaptureByDefault() {
        // #585: a capture where too many beats were noise must be refused even though >= minBeats clean
        // beats survive. 24 valid 850 ms + 16 out-of-range (10 ms) → 16/40 = 0.40 rejected > the default
        // 0.35 ceiling → .insufficient (an honest "sit still and try again"), never a fabricated number.
        var rr = knownCleanSeries()            // 24 clean
        rr.append(contentsOf: Array(repeating: 10, count: 16))   // 16 out-of-range → range-dropped
        guard case let .insufficient(clean, needed, input) = SpotHrvReading.compute(rr) else {
            return XCTFail("0.40 rejected must be refused by the default spot gate")
        }
        XCTAssertEqual(needed, HRVAnalyzer.minBeats)
        XCTAssertEqual(input, 40)
        XCTAssertEqual(clean, 0)               // refusal reports the empty result's nClean
    }

    func testSpotGateRelaxedAllowsTheSameNoisyCapture() {
        // Passing a permissive ceiling (> 0.40) lets the same 24-clean capture through — proving the gate,
        // not the clean-beat count, is what refused it above.
        var rr = knownCleanSeries()
        rr.append(contentsOf: Array(repeating: 10, count: 16))
        guard case let .reading(_, _, beats, _) = SpotHrvReading.compute(rr, maxRejectedFraction: 0.5) else {
            return XCTFail("a 0.5 ceiling must allow the 0.40-rejected capture")
        }
        XCTAssertEqual(beats, 24)
    }

    func testMeanHrFromNnMatchesDefinition() {
        XCTAssertEqual(SpotHrvReading.meanHrFromNN(1000.0)!, 60.0, accuracy: 1e-9)
        XCTAssertEqual(SpotHrvReading.meanHrFromNN(800.0)!, 75.0, accuracy: 1e-9)
        XCTAssertNil(SpotHrvReading.meanHrFromNN(nil))
        XCTAssertNil(SpotHrvReading.meanHrFromNN(0.0))
        XCTAssertNil(SpotHrvReading.meanHrFromNN(-1.0))
    }

    func testCaveatIsSourceAwareAndClean() {
        let ppg = SpotHrvReading.caveatFor(.opticalPPG)
        let strap = SpotHrvReading.caveatFor(.chestStrap)
        let unknown = SpotHrvReading.caveatFor(.unknown)

        // PPG caveat must call out the noisier optical source; chest strap must not.
        XCTAssertTrue(ppg.contains("optical pulse signal"), "PPG caveat mentions the optical pulse signal")
        XCTAssertFalse(strap.contains("optical pulse signal"), "chest-strap caveat omits the PPG note")
        XCTAssertEqual(strap, unknown, "unknown source uses the base caveat")

        // Every caveat states the universal "spot, not overnight baseline" limit.
        for c in [ppg, strap, unknown] {
            XCTAssertTrue(c.contains("spot reading"), "states it is a spot reading")
            XCTAssertTrue(c.contains("overnight HRV baseline"), "states it is not the overnight baseline")
            // House rule: no em-dashes anywhere in user-facing copy.
            XCTAssertFalse(c.contains("—"), "no em-dash in caveat")
        }
    }
}
