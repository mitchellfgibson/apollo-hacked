import Foundation
import WhoopProtocol

// RespRateAnalyzer.swift — respiration rate (breaths/min) from the v26 24 Hz PPG waveform.
//
// Respiration modulates the PPG pulse amplitude: each breath inflates/deflates the pulse
// envelope once (amplitude modulation, one of the three classic derived-respiration signals).
// Method per 60 s window:
//
//   1. Run PPGPulseAnalyzer; skip windows whose pulse quality is motion-corrupted.
//   2. Track the pulse envelope at the NATIVE 24 Hz rate — pulse-band filter → rectify →
//      low-pass into the resp band (a classic envelope detector) — then decimate to 4 Hz.
//      Deliberately NOT a per-beat amplitude series: any beat-rate sampling aliases the
//      beat-to-sample phase drift into the respiratory band and fakes a breathing peak
//      (an unmodulated 70 bpm carrier read as a coherent 30/min; caught in tests).
//   3. Hann-window the detrended envelope and evaluate the periodogram at 1 breath/min
//      resolution over the respiratory band (0.10–0.60 Hz = 6–36 breaths/min), SKIPPING
//      bins that coincide with pulse-rate × sample-clock intermodulation lines
//      (|k·fP − l·fs| — the picket-fence beat note; a peak there is artifact, not breathing).
//   4. Accept the window only when the top bin holds a clear share of the band power
//      (`minPeakShare`) — a flat spectrum means no coherent breathing signal.
//
// Night aggregate: median of valid window rates; `quality` = valid/attempted windows.
// Requires ≥ `minValidWindows` valid windows before reporting anything.
//
// Pure and deterministic; no database. See RespRateAnalyzerTests for the synthetic-AM
// validation (carrier HR + amplitude modulation at a known breathing rate).

public enum RespRateAnalyzer {

    /// Analysis window length (seconds).
    public static let windowSeconds = 60
    /// Hop between consecutive windows (seconds) — 50% overlap.
    public static let hopSeconds = 30
    /// Minimum fraction of a window's seconds that must have v26 records.
    public static let minCoverageRatio = 0.8
    /// Maximum tolerated recording gap inside a window (seconds).
    public static let maxGapSeconds = 4
    /// Windows with pulse quality below this are motion-corrupted — skipped.
    public static let minPulseQuality = 0.5
    /// Minimum beats in a window for a trustworthy envelope.
    public static let minBeatsPerWindow = 30
    /// Envelope resample rate (Hz).
    public static let resampleHz = 4.0
    /// Respiratory band (Hz): 6–36 breaths/min.
    public static let respBandLoHz = 0.10
    public static let respBandHiHz = 0.60
    /// Minimum share of band power in the top bin to call a coherent respiratory peak. Measured
    /// separation (synthetic AM at 24 Hz): a real breathing peak concentrates 0.94–0.97 of band
    /// power, while an UNMODULATED carrier leaves a diffuse spectrum whose best bin holds only ~0.40
    /// (a residual-leakage artifact that otherwise reported a phantom ~19/min). 0.5 sits in that gap
    /// — high enough to reject the artifact, low enough to keep genuine respiration.
    public static let minPeakShare = 0.5
    /// Minimum valid windows before a nightly rate is reported.
    public static let minValidWindows = 3

    /// Aggregate respiration result over a span of v26 records.
    public struct RespResult: Equatable, Sendable {
        /// Median breaths/min across valid windows, or nil when insufficient clean data.
        public let breathsPerMin: Double?
        /// Valid windows ÷ attempted windows [0,1].
        public let quality: Double
        /// Number of valid windows contributing to `breathsPerMin`.
        public let nWindows: Int

        public init(breathsPerMin: Double?, quality: Double, nWindows: Int) {
            self.breathsPerMin = breathsPerMin; self.quality = quality; self.nWindows = nWindows
        }
    }

    /// Analyze a span of per-second v26 waveform records (any order; gaps tolerated).
    public static func analyze(_ seconds: [PPGWaveformSample]) -> RespResult {
        guard !seconds.isEmpty else { return RespResult(breathsPerMin: nil, quality: 0, nWindows: 0) }
        var byTs: [Int: [Int]] = [:]
        for s in seconds where byTs[s.ts] == nil { byTs[s.ts] = s.samples }
        let keys = byTs.keys.sorted()
        guard let t0 = keys.first, let t1 = keys.last,
              t1 - t0 + 1 >= windowSeconds else {
            return RespResult(breathsPerMin: nil, quality: 0, nWindows: 0)
        }

        var rates: [Double] = []
        var attempted = 0
        var start = t0
        while start + windowSeconds <= t1 + 1 {
            defer { start += hopSeconds }
            var present: [Int] = []
            var wSamples: [Double] = []
            wSamples.reserveCapacity(windowSeconds * Int(PPGPulseAnalyzer.sampleRate))
            for t in start..<(start + windowSeconds) {
                if let s = byTs[t] {
                    present.append(t)
                    wSamples.append(contentsOf: s.map(Double.init))
                }
            }
            guard Double(present.count) >= Double(windowSeconds) * minCoverageRatio else { continue }
            var gapOK = true
            for i in 1..<present.count where present[i] - present[i - 1] - 1 > maxGapSeconds {
                gapOK = false; break
            }
            guard gapOK else { continue }
            attempted += 1
            if let r = windowRate(wSamples, fs: PPGPulseAnalyzer.sampleRate) {
                rates.append(r)
            }
        }

        guard rates.count >= minValidWindows else {
            return RespResult(breathsPerMin: nil,
                              quality: attempted > 0 ? Double(rates.count) / Double(attempted) : 0,
                              nWindows: rates.count)
        }
        return RespResult(breathsPerMin: PPGPulseAnalyzer.median(rates),
                          quality: attempted > 0 ? Double(rates.count) / Double(attempted) : 0,
                          nWindows: rates.count)
    }


    /// Respiratory rate (breaths/min) for one contiguous window of raw samples, or nil.
    /// Exposed for tests; the aggregate entry point is `analyze(_:)`.
    static func windowRate(_ x: [Double], fs: Double) -> Double? {
        let pulse = PPGPulseAnalyzer.analyze(x)
        guard pulse.pulseBpm != nil,
              pulse.quality >= minPulseQuality,
              pulse.peakTimes.count >= minBeatsPerWindow else { return nil }

        // Amplitude-modulation DRS at the NATIVE sample rate — a classic envelope detector
        // (pulse-band filter → rectify → low-pass into the resp band). Deliberately NOT a
        // beat-sampled series: any per-beat sampling (amplitude OR timing) aliases the
        // beat-to-sample phase drift into the respiratory band and masquerades as breathing
        // (an unmodulated 70 bpm carrier read as a coherent 30/min — caught in tests).
        // Rectification at 24 Hz has Nyquist 12 Hz, so nothing folds into 0.1–0.6 Hz.
        let hp = PPGPulseAnalyzer.highpass(
            x, window: Int((fs * PPGPulseAnalyzer.highPassWindowSeconds).rounded()))
        let pulseBand = PPGPulseAnalyzer.Biquad.lowpass(
            fc: PPGPulseAnalyzer.lowPassCutoffHz, fs: fs).apply(hp)
        // Envelope low-pass, applied TWICE (cascaded → 4th-order, ~−24 dB/oct) as the anti-alias
        // filter ahead of the 24→4 Hz decimation. A single 2nd-order stage at 0.7 Hz leaves too
        // much of the rectified pulse's dominant 2·fP component (≈2.3 Hz), which folds back into the
        // respiratory band on decimation and shows up as a strong phantom peak (~19/min on an
        // UNMODULATED 70 bpm carrier). The cascade crushes that fold — dropping the phantom's band
        // share from ~0.76 to ~0.27, safely below `minPeakShare` — while still passing the 0.1–0.6 Hz
        // respiratory band essentially untouched, so genuine breathing peaks are unaffected.
        let rect = pulseBand.map { abs($0) }
        let aa = PPGPulseAnalyzer.Biquad.lowpass(fc: 0.7, fs: fs)
        let env24 = aa.apply(aa.apply(rect))
        let step = max(1, Int((fs / resampleHz).rounded()))
        var env: [Double] = []
        env.reserveCapacity(env24.count / step + 1)
        var i = 0
        while i < env24.count { env.append(env24[i]); i += step }
        let nU = env.count
        guard nU >= 8 else { return nil }

        // Detrend + Hann window. A flat envelope (an unmodulated carrier) has no respiratory
        // content — bail before the periodogram can crown a numerical-noise peak. The gate is
        // relative (1% of the mean envelope): real respiratory AM is several % even when weak.
        let mean = env.reduce(0, +) / Double(nU)
        let envVar = env.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(nU)
        guard envVar.squareRoot() > max(1e-9, 0.01 * abs(mean)) else { return nil }
        for i in 0..<nU {
            let w = 0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(nU - 1)))
            env[i] = (env[i] - mean) * w
        }

        // Periodogram over the respiratory band at 1 breath/min resolution, SKIPPING the
        // pulse-clock intermodulation bins. Sampling at fs intermodulates the pulse rate fP
        // with the sample clock: spectral lines at |k·fP − l·fs| — the picket-fence beat note
        // between heart rate and sample rate (70 bpm @ 24 Hz puts strong lines at exactly
        // 10/20/30 per min, which is why an unmodulated carrier read as "30/min" before this
        // guard). A real respiratory peak sits BETWEEN those lines; a peak ON one is the
        // sampling artifact, not breathing.
        let fPulse = pulse.pulseBpm! / 60   // non-nil: guarded above
        var bestRate = 0.0, bestPower = 0.0, totalPower = 0.0
        var rate = respBandLoHz * 60
        while rate <= respBandHiHz * 60 + 1e-9 {
            defer { rate += 1.0 }
            let f = rate / 60
            if Self.isPulseClockAlias(f: f, pulseHz: fPulse, fs: fs) { continue }
            var re = 0.0, im = 0.0
            for i in 0..<nU {
                let ph = -2 * Double.pi * f * Double(i) / resampleHz
                re += env[i] * cos(ph)
                im += env[i] * sin(ph)
            }
            let p = re * re + im * im
            totalPower += p
            if p > bestPower { bestPower = p; bestRate = rate }
        }
        guard totalPower > 0, bestPower / totalPower >= minPeakShare else { return nil }
        return bestRate
    }

    /// True when frequency `f` (Hz) coincides with a pulse-rate × sample-clock intermodulation
    /// line |k·fP − l·fs| (k ≤ 64), within ±1.5 bins (1 bin = 1 breath/min). The margin covers
    /// Hann-window mainlobe leakage: a strong artifact line otherwise crowns its immediate
    /// neighbour bins (the "30/min" artifact re-peaking at 29). Such lines are sampling
    /// artifacts (the picket-fence beat note), not physiology.
    static func isPulseClockAlias(f: Double, pulseHz: Double, fs: Double) -> Bool {
        guard pulseHz > 0, fs > 0 else { return false }
        var k = 1.0
        while k <= 64 {
            let l = (k * pulseHz / fs).rounded()
            let alias = abs(k * pulseHz - l * fs)
            if abs(alias - f) < 1.5 / 60.0 { return true }
            k += 1
        }
        return false
    }
}
