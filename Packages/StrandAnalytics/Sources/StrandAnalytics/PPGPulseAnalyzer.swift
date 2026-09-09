import Foundation

// PPGPulseAnalyzer.swift — pulse rate + beat detection from the WHOOP 5 v26 24 Hz optical PPG.
//
// The v26 record carries a raw AC-coupled PPG waveform (24 LE-i16 samples/second, no absolute
// unit). This analyzer turns one contiguous window of that waveform into a pulse estimate:
//
//   1. High-pass by moving-average subtraction (2 s window ≈ 0.5 Hz cutoff) — kills the
//      respiratory baseline wander and DC drift so the pulse waveform stands out.
//   2. Low-pass 2nd-order Butterworth biquad at 4 Hz — the pulse fundamental + first harmonic
//      live under ~4 Hz for any physiological rate (≤ 200 bpm); everything above is noise.
//   3. Peak detection with an adaptive amplitude threshold (mean + k·std) and a 300 ms
//      refractory period (physiological max ~200 bpm); a taller peak inside the refractory
//      window replaces the earlier one rather than double-counting.
//   4. Inter-beat intervals filtered to [300, 2000] ms; `quality` = fraction of the window
//      covered by plausible IBIs — the motion-artifact gate downstream consumers key on.
//
// Validated against synthetic PPG at known rates (see PPGPulseAnalyzerTests); the repo's v26
// capture analysis established the waveform is genuinely pulse-locked (autocorrelation peak at
// the concurrently-recorded HR), so a clean window here should track the v18 heart rate.
//
// Pure and deterministic: no database, no DSP dependencies — same conventions as HRVAnalyzer.

public enum PPGPulseAnalyzer {

    /// v26 sample rate: 24 samples per 1-second record.
    public static let sampleRate: Double = 24
    /// Moving-average high-pass window (seconds) ≈ 0.5 Hz cutoff.
    public static let highPassWindowSeconds: Double = 2.0
    /// Low-pass biquad cutoff (Hz) — pulse fundamental + first harmonic.
    public static let lowPassCutoffHz: Double = 4.0
    /// Adaptive peak threshold: mean + k·std of the filtered signal.
    public static let thresholdK: Double = 0.5
    /// Peak refractory period (ms) — 300 ms ≈ 200 bpm max detectable rate.
    public static let refractoryMs: Double = 300
    /// Plausible inter-beat interval bounds (ms): 200 bpm … 30 bpm.
    public static let ibiMinMs: Double = 300
    public static let ibiMaxMs: Double = 2000
    /// Minimum plausible beats for a pulse estimate at all.
    public static let minBeats: Int = 4

    /// Result of running pulse detection over one window.
    public struct PulseResult: Equatable, Sendable {
        /// Median-based pulse rate (bpm), or nil when too few plausible beats.
        public let pulseBpm: Double?
        /// Plausible inter-beat intervals (ms), in order.
        public let ibiMs: [Double]
        /// Fraction of the window covered by plausible IBIs [0,1] — the artifact gate.
        public let quality: Double
        /// Beat times in seconds from window start (parabolic-interpolated, sub-sample).
        public let peakTimes: [Double]
        /// Beat amplitudes (parabolic-interpolated filtered values; same order as `peakTimes`).
        public let peakAmps: [Double]

        public init(pulseBpm: Double?, ibiMs: [Double], quality: Double,
                    peakTimes: [Double], peakAmps: [Double]) {
            self.pulseBpm = pulseBpm; self.ibiMs = ibiMs; self.quality = quality
            self.peakTimes = peakTimes; self.peakAmps = peakAmps
        }

        /// Empty window result.
        public static let none = PulseResult(pulseBpm: nil, ibiMs: [], quality: 0,
                                             peakTimes: [], peakAmps: [])
    }

    /// Analyze one contiguous window of raw ADC counts.
    public static func analyze(_ samples: [Int]) -> PulseResult {
        analyze(samples.map(Double.init))
    }

    /// Analyze one contiguous window of samples (already Doubles).
    public static func analyze(_ x: [Double]) -> PulseResult {
        let fs = sampleRate
        guard x.count >= Int(fs) else { return .none }   // need ≥ 1 s of data

        // 1) High-pass: subtract a trailing-window moving average (prefix sums for O(n)).
        let hp = highpass(x, window: Int((fs * highPassWindowSeconds).rounded()))
        // 2) Low-pass biquad.
        let y = Biquad.lowpass(fc: lowPassCutoffHz, fs: fs).apply(hp)

        // 3) Adaptive-threshold peak detection with refractory.
        let n = y.count
        let mean = y.reduce(0, +) / Double(n)
        let varSum = y.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let std = (varSum / Double(n)).squareRoot()
        guard std > 1e-9 else { return .none }   // flatline — no pulse to find
        let thresh = mean + thresholdK * std
        let refractory = max(1, Int((refractoryMs / 1000.0 * fs).rounded()))

        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            if y[i] > thresh && y[i] >= y[i - 1] && y[i] > y[i + 1] {
                if let last = peaks.last, i - last < refractory {
                    if y[i] > y[last] { peaks[peaks.count - 1] = i }   // keep the taller
                } else {
                    peaks.append(i)
                }
            }
            i += 1
        }

        // 3b) Parabolic interpolation around each peak sample: sub-sample beat time AND
        // amplitude. Without it the peak's sampled value jitters with the beat-to-sample phase
        // drift (picket-fence effect), which aliases into the respiratory band downstream and
        // masquerades as breathing. delta = 0.5(l−r)/(l−2c+r), clamped for degenerate shapes.
        var peakTimes: [Double] = []
        var peakAmps: [Double] = []
        for p in peaks {
            let l = y[p - 1], c = y[p], r = y[p + 1]
            let denom = l - 2 * c + r
            var delta = abs(denom) > 1e-12 ? 0.5 * (l - r) / denom : 0
            delta = min(1, max(-1, delta))
            peakTimes.append((Double(p) + delta) / fs)
            peakAmps.append(c - 0.25 * (l - r) * delta)
        }

        // 4) IBIs filtered to the plausible range.
        var ibis: [Double] = []
        if peakTimes.count >= 2 {
            for k in 1..<peakTimes.count {
                let ms = (peakTimes[k] - peakTimes[k - 1]) * 1000.0
                if (ibiMinMs...ibiMaxMs).contains(ms) { ibis.append(ms) }
            }
        }
        let windowMs = Double(n) / fs * 1000.0
        let quality = min(1.0, ibis.reduce(0, +) / windowMs)
        let bpm: Double? = ibis.count >= minBeats ? 60_000.0 / median(ibis) : nil

        return PulseResult(pulseBpm: bpm, ibiMs: ibis, quality: quality,
                           peakTimes: peakTimes, peakAmps: peakAmps)
    }

    // MARK: - internals

    /// Moving-average-subtraction high-pass. `window` is the MA width in samples (clamped ≥ 1).
    static func highpass(_ x: [Double], window: Int) -> [Double] {
        let n = x.count
        let w = max(1, window)
        var pref = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pref[i + 1] = pref[i] + x[i] }
        let half = w / 2
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - half), hi = min(n, i + half + 1)
            out[i] = x[i] - (pref[hi] - pref[lo]) / Double(hi - lo)
        }
        return out
    }

    /// Median of a non-empty array (average of the two middle values for even counts).
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// 2nd-order Butterworth low-pass biquad (RBJ cookbook), applied zero-phase-free
    /// (single forward pass — group delay is irrelevant for beat timing at this scale).
    struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        static func lowpass(fc: Double, fs: Double) -> Biquad {
            let w0 = 2 * Double.pi * fc / fs
            let cw = cos(w0), sw = sin(w0)
            let q = 1.0 / (2.0).squareRoot()
            let alpha = sw / (2 * q)
            let a0 = 1 + alpha
            return Biquad(b0: (1 - cw) / 2 / a0, b1: (1 - cw) / a0, b2: (1 - cw) / 2 / a0,
                          a1: -2 * cw / a0, a2: (1 - alpha) / a0)
        }

        func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in x.indices {
                let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                y[i] = v
                x2 = x1; x1 = x[i]
                y2 = y1; y1 = v
            }
            return y
        }
    }
}
