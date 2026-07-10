import SwiftUI
import StrandDesign
import WhoopStore
import WhoopProtocol

/// Heart-rate-through-the-night line chart for the Sleep screen. Plots real `HRSample`s across
/// the night window on the same x-axis as the reconstructed sleep-stage intervals. When a stage
/// is selected (via the top-right dropdown), the whole trace dims and the portions that fall
/// inside that stage's intervals are redrawn in the stage color — so you can read "what was my
/// heart rate during REM / deep / etc." at a glance.
struct NightHRChart: View {
    /// HR samples in absolute unix seconds.
    let samples: [HRSample]
    /// Night start in unix seconds — the x-axis origin.
    let nightStartTs: Int
    /// Night end in unix seconds — the x-axis extent.
    let nightEndTs: Int
    /// Reconstructed stage intervals (seconds from night start).
    let intervals: [SleepInterval]
    /// The stage the user picked, or nil for "all".
    let selectedStage: SleepStage?
    /// When true, draw a clock (HH:mm) axis along the bottom and reserve room for it.
    var showsTimeAxis: Bool = false
    /// Sleep-onset offset (seconds from night start) — draws a labelled "Asleep" marker. nil = hide.
    var onsetOffset: Double? = nil
    /// Final-wake offset (seconds from night start) — draws a labelled "Awake" marker. nil = hide.
    var wakeOffset: Double? = nil

    var height: CGFloat = NoopMetrics.chartHeight

    /// Height reserved at the bottom for the time axis labels (0 when hidden).
    private var axisHeight: CGFloat { showsTimeAxis ? 18 : 0 }

    private var span: Double { max(1, Double(nightEndTs - nightStartTs)) }

    /// Window (in samples) for the moving-average smoother. At ~1 Hz this is ~a 30 s window — enough
    /// to iron out the beat-to-beat jitter and dropout spikes into a clean physiological curve while
    /// still following real rises/falls across the night.
    private static let smoothWindow = 31

    /// The samples actually drawn: zero/garbage bpm dropped, then a CENTERED moving average applied.
    /// Computed once and reused by the base trace, the highlight segments, and the y-range so
    /// everything shares the same smooth line. Empty in → empty out.
    private var smoothed: [HRSample] {
        let clean = samples.filter { $0.bpm > 0 }
        guard clean.count > 2 else { return clean }
        let half = Self.smoothWindow / 2
        let n = clean.count
        var out: [HRSample] = []
        out.reserveCapacity(n)
        // TRUE O(n) sliding window: keep a running sum, adding the entering sample and removing the
        // leaving one as the centered window advances — no inner loop, so this stays cheap even at
        // ~35k samples per render (hover/animation re-evaluations don't stutter).
        var sum = 0
        var lo = 0, hi = -1
        for i in 0..<n {
            let newLo = Swift.max(0, i - half)
            let newHi = Swift.min(n - 1, i + half)
            while hi < newHi { hi += 1; sum += clean[hi].bpm }
            while lo < newLo { sum -= clean[lo].bpm; lo += 1 }
            let avg = Int((Double(sum) / Double(hi - lo + 1)).rounded())
            out.append(HRSample(ts: clean[i].ts, bpm: avg))
        }
        return out
    }

    // HR range for the y-axis, padded a little — from the SMOOTHED series so the padding matches
    // the drawn line (raw spikes no longer inflate the range and flatten the curve).
    private var hrRange: ClosedRange<Double> {
        let bpms = smoothed.map { Double($0.bpm) }
        guard let lo = bpms.min(), let hi = bpms.max(), hi > lo else { return 40...120 }
        let pad = max(4, (hi - lo) * 0.12)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        GeometryReader { geo in
            // Plot area excludes the bottom axis strip so the trace never overlaps the clock labels.
            let plotSize = CGSize(width: geo.size.width, height: geo.size.height - axisHeight)
            let range = hrRange
            let smoothedSamples = smoothed
            let base = tracePath(in: plotSize, range: range, samples: smoothedSamples)
            ZStack(alignment: .topLeading) {
                // Base trace — full night. Dimmed when a stage is selected so the highlight pops.
                base.stroke(StrandPalette.textSecondary.opacity(selectedStage == nil ? 0.9 : 0.22),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // Highlighted segments for the selected stage.
                if let stage = selectedStage {
                    ForEach(highlightRanges(for: stage), id: \.self) { r in
                        highlightPath(in: plotSize, range: range, stage: stage, r: r, source: smoothedSamples)
                            .stroke(StrandPalette.sleepStageColor(stage),
                                    style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .overlay(alignment: .topLeading) { markers(plotSize: plotSize) }
            .frame(width: plotSize.width, height: plotSize.height)
            .overlay(alignment: .topLeading) { yLabels(range: range, h: plotSize.height) }
            .overlay(alignment: .bottom) {
                if showsTimeAxis {
                    timeAxis(width: geo.size.width)
                        .frame(height: axisHeight)
                        .offset(y: axisHeight)   // sit in the reserved strip below the plot
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Geometry helpers

    /// Map a sample to a point in a chart rect of the given size.
    private func point(_ s: HRSample, in size: CGSize, range: ClosedRange<Double>) -> CGPoint {
        let x = CGFloat(Double(s.ts - nightStartTs) / span) * size.width
        let t = (Double(s.bpm) - range.lowerBound) / (range.upperBound - range.lowerBound)
        let y = size.height - CGFloat(t) * size.height
        return CGPoint(x: x, y: y)
    }

    /// A polyline through the given samples.
    private func tracePath(in size: CGSize, range: ClosedRange<Double>, samples: [HRSample]) -> Path {
        Path { p in
            let pts = samples.map { point($0, in: size, range: range) }
            guard let first = pts.first else { return }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    /// The trace restricted to a single stage interval [r]. Draws from the SMOOTHED series so a
    /// highlighted stage matches the base line exactly.
    private func highlightPath(in size: CGSize, range: ClosedRange<Double>,
                               stage: SleepStage, r: ClosedRange<Double>, source: [HRSample]) -> Path {
        let seg = source.filter {
            let o = Double($0.ts - nightStartTs); return o >= r.lowerBound && o <= r.upperBound
        }
        return tracePath(in: size, range: range, samples: seg)
    }

    /// The seconds-from-start ranges covered by the selected stage's intervals.
    private func highlightRanges(for stage: SleepStage) -> [ClosedRange<Double>] {
        intervals
            .filter { $0.stage == stage && $0.end > $0.start }
            .map { $0.start...$0.end }
    }

    /// Vertical onset ("Asleep") and final-wake ("Awake") markers — dashed lines with a small top
    /// label — so you can read at a glance when you fell asleep and woke.
    @ViewBuilder
    private func markers(plotSize: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let onsetOffset { marker(at: onsetOffset, label: "Asleep", size: plotSize) }
            if let wakeOffset { marker(at: wakeOffset, label: "Awake", size: plotSize) }
        }
        .frame(width: plotSize.width, height: plotSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func marker(at offset: Double, label: String, size: CGSize) -> some View {
        let frac = max(0, min(1, offset / span))
        let x = CGFloat(frac) * size.width
        // Drop the label into the LOWER third of the chart, where the HR trace rarely reaches — so
        // it never sits on top of the data or collides with the top-left "bpm" y-axis label.
        let labelY = size.height * 0.72
        ZStack(alignment: .top) {
            Rectangle()
                .fill(StrandPalette.textSecondary.opacity(0.35))
                .frame(width: 1, height: size.height)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(StrandPalette.surfaceRaised, in: Capsule())
                .overlay(Capsule().stroke(StrandPalette.hairline, lineWidth: 1))
                .fixedSize()
                .offset(y: labelY)
        }
        .frame(width: 60)                 // room for the label to center on the line
        .offset(x: x - 30)                // center the 60pt box on the marker x
    }

    /// Clock (HH:mm) labels along the bottom, at ~hourly ticks across the night. Each label is
    /// positioned by its x-fraction so it sits under the matching point on the trace.
    private func timeAxis(width: CGFloat) -> some View {
        let ticks = axisTicks()
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { ts in
                let frac = Double(ts - nightStartTs) / span
                Text(NightHRChart.axisFmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))
                    .font(.system(size: 10))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize()
                    .alignmentGuide(.leading) { d in d.width / 2 }   // center the label on its tick
                    .offset(x: CGFloat(frac) * width)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Choose ~5–7 evenly spaced tick timestamps across the night, snapped to whole hours so the
    /// labels read as clean clock times (11:00, 12:00, …) rather than arbitrary minutes.
    private func axisTicks() -> [Int] {
        let total = nightEndTs - nightStartTs
        guard total > 0 else { return [] }
        let hours = Double(total) / 3600.0
        // Aim for ≤6 labels: step up the hour interval as the night gets longer.
        let step = hours <= 6 ? 1 : (hours <= 10 ? 2 : 3)
        var ticks: [Int] = []
        // First whole hour at or after nightStart.
        var t = (nightStartTs / 3600 + (nightStartTs % 3600 == 0 ? 0 : 1)) * 3600
        while t <= nightEndTs {
            ticks.append(t)
            t += step * 3600
        }
        return ticks
    }

    private static let axisFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// Faint min/max bpm labels up the left edge.
    private func yLabels(range: ClosedRange<Double>, h: CGFloat) -> some View {
        VStack {
            Text("\(Int(range.upperBound)) bpm")
            Spacer()
            Text("\(Int(range.lowerBound)) bpm")
        }
        .font(.system(size: 10))
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.vertical, 2)
    }

    private var accessibilityText: String {
        let bpms = samples.map { $0.bpm }.filter { $0 > 0 }
        guard let lo = bpms.min(), let hi = bpms.max() else { return "No heart-rate data for this night." }
        let stageWord = selectedStage.map { " Highlighting \($0.label)." } ?? ""
        return "Heart rate through the night, \(lo) to \(hi) bpm.\(stageWord)"
    }
}
