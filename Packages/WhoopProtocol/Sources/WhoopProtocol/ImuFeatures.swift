import Foundation

/// Per-second motion features derived from a v21 raw-IMU record (100 Hz, 6 axes).
///
/// WHY FEATURES AND NOT THE RAW BUFFER. A v21 record is 1244 B for ONE second of wear. Banking the
/// raw samples is ~100 MB/day and, on this hardware, the strap's own history is only served once —
/// so the storage decision has to be made before the data is acked away. The consumers that actually
/// exist (sleep staging, wake detection) want per-epoch motion intensity, not the waveform, so this
/// stores the summary at ~48 bytes/second and leaves the waveform out. If a waveform consumer is
/// ever validated, `Whoop5RawImu`-style raw capture can be added alongside; nothing here forecloses it.
///
/// SCALES are the hardware-validated ones for the WHOOP 5/MG IMU:
///   accelerometer  1/4096 g per LSB
///   gyroscope      2000/32768 (°/s) per LSB  (±2000 dps full scale)
public enum ImuFeatures {

    public static let accelScale = 1.0 / 4096.0
    public static let gyroScale  = 2000.0 / 32768.0

    /// Threshold on |‖a‖ − mean‖a‖| that counts a sample as "moving", in g. 0.02 g sits above the
    /// resting noise floor measured on this sensor (±11 LSB ≈ 0.0027 g) with an order of magnitude
    /// of headroom, so still wear reads zero rather than accumulating noise.
    public static let activityThresholdG = 0.02

    /// Compute the per-second summary from the six raw i16 columns. Returns nil unless all six axes
    /// decoded with matching sample counts — a partial record is not summarised, because a missing
    /// axis silently biases every magnitude downward.
    public static func summarise(ax: [Int], ay: [Int], az: [Int],
                                 gx: [Int], gy: [Int], gz: [Int]) -> ImuFeatureValues? {
        let n = ax.count
        guard n > 1, ay.count == n, az.count == n,
              gx.count == n, gy.count == n, gz.count == n else { return nil }

        var accelMag = [Double](repeating: 0, count: n)
        var gyroMagSum = 0.0
        for i in 0..<n {
            let x = Double(ax[i]) * accelScale
            let y = Double(ay[i]) * accelScale
            let z = Double(az[i]) * accelScale
            accelMag[i] = (x * x + y * y + z * z).squareRoot()

            let rx = Double(gx[i]) * gyroScale
            let ry = Double(gy[i]) * gyroScale
            let rz = Double(gz[i]) * gyroScale
            gyroMagSum += (rx * rx + ry * ry + rz * rz).squareRoot()
        }

        let mean = accelMag.reduce(0, +) / Double(n)
        var variance = 0.0
        var jerkSum = 0.0
        var activity = 0
        for i in 0..<n {
            let d = accelMag[i] - mean
            variance += d * d
            if abs(d) > activityThresholdG { activity += 1 }
            if i > 0 { jerkSum += abs(accelMag[i] - accelMag[i - 1]) }
        }
        let sd = (variance / Double(n)).squareRoot()

        return ImuFeatureValues(
            accelMagMean: mean,
            accelMagSd: sd,
            jerkMean: jerkSum / Double(n - 1),
            gyroMagMean: gyroMagSum / Double(n),
            activityCount: activity,
            sampleCount: n
        )
    }
}

/// The derived per-second motion summary, in physical units.
public struct ImuFeatureValues: Equatable, Sendable {
    /// Mean |acceleration| in g. At rest this is the ~1 g gravity shell.
    public let accelMagMean: Double
    /// Standard deviation of |acceleration| in g — the primary movement-intensity signal.
    public let accelMagSd: Double
    /// Mean absolute second-to-second change in |acceleration| (g). Sensitive to movement onset.
    public let jerkMean: Double
    /// Mean |angular rate| in °/s.
    public let gyroMagMean: Double
    /// Samples in this second whose |acceleration| deviates from the mean by more than
    /// `activityThresholdG` — the classic actigraphy count.
    public let activityCount: Int
    /// Samples the summary was computed from (100 on a complete record).
    public let sampleCount: Int

    public init(accelMagMean: Double, accelMagSd: Double, jerkMean: Double,
                gyroMagMean: Double, activityCount: Int, sampleCount: Int) {
        self.accelMagMean = accelMagMean
        self.accelMagSd = accelMagSd
        self.jerkMean = jerkMean
        self.gyroMagMean = gyroMagMean
        self.activityCount = activityCount
        self.sampleCount = sampleCount
    }
}
