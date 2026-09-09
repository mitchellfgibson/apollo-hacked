import XCTest
@testable import StrandAnalytics

/// Synthetic PPG at 24 Hz: pulse carrier at `hrBpm` (fundamental + 2nd harmonic), optional
/// amplitude modulation at `respPerMin` (depth `amDepth`), deterministic centered noise.
/// Shared by PPGPulseAnalyzerTests and RespRateAnalyzerTests (same test module).
func synthPPGWaveform(seconds: Int, hrBpm: Double, respPerMin: Double? = nil,
                      amDepth: Double = 0, noiseAmp: Double = 0, seed: UInt64 = 42) -> [Int] {
    let fs = 24.0
    let fPulse = hrBpm / 60.0
    var rng = seed
    return (0..<seconds * Int(fs)).map { i in
        let t = Double(i) / fs
        let phase = 2 * Double.pi * fPulse * t
        var v = sin(phase) + 0.4 * sin(2 * phase + 0.5)
        if let r = respPerMin {
            v *= 1 + amDepth * sin(2 * Double.pi * (r / 60) * t)
        }
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        let noise = (Double(Int64(rng >> 33)) / Double(Int64(Int32.max)) - 0.5) * noiseAmp
        return Int(((v + noise) * 1000).rounded())
    }
}

final class PPGPulseAnalyzerTests: XCTestCase {

    func testRecoversKnownRates() {
        for (hr, tol) in [(60.0, 2.0), (90.0, 2.0), (120.0, 2.5)] {
            let r = PPGPulseAnalyzer.analyze(synthPPGWaveform(seconds: 60, hrBpm: hr))
            XCTAssertNotNil(r.pulseBpm, "no pulse found at \(hr) bpm")
            XCTAssertEqual(r.pulseBpm ?? -1, hr, accuracy: tol, "rate off at \(hr) bpm")
            XCTAssertGreaterThan(r.quality, 0.8, "quality low at \(hr) bpm")
        }
    }

    func testFlatlineYieldsNoPulse() {
        let r = PPGPulseAnalyzer.analyze([Int](repeating: 500, count: 24 * 60))
        XCTAssertNil(r.pulseBpm)
        XCTAssertEqual(r.quality, 0)
    }

    func testShortWindowYieldsNoPulse() {
        let r = PPGPulseAnalyzer.analyze([1200, -300, 450])
        XCTAssertNil(r.pulseBpm)
        XCTAssertEqual(r.quality, 0)
    }

    func testNoiseDegradesQuality() {
        let clean = PPGPulseAnalyzer.analyze(synthPPGWaveform(seconds: 60, hrBpm: 70))
        let noisy = PPGPulseAnalyzer.analyze(synthPPGWaveform(seconds: 60, hrBpm: 70, noiseAmp: 4))
        XCTAssertLessThan(noisy.quality, clean.quality)
    }
}
