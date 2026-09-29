import SwiftUI

// MARK: - TypicalRangeBar (WHOOP detail "typical range" bar)
//
// "Solid = you, hatch = the context." A horizontal bar where a DIAGONAL-HATCH track marks the
// typical / reference RANGE (lower…upper, as fractions of the bar) and a SOLID coloured fill marks
// the user's VALUE. Mirrors WHOOP's sleep-stage and metric range rows: the eye instantly sees whether
// you landed inside, below or above the typical band, without a legend.
//
// This is a shared primitive so any screen can adopt the pattern with data it ALREADY has — pass a
// 0…1 value fraction and a 0…1 typical range. It invents no data: when no range is supplied it renders
// the value fill alone over a plain inset track (still flat + crisp, WHOOP-style).
//
// Two surfaces:
//   • `TypicalRangeBar`      — just the bar (swatch-free), for inline use under a value.
//   • `TypicalRangeRow`      — the full WHOOP row: [swatch] UPPERCASE LABEL · coloured value · bar ·
//                              right-aligned white trailing (e.g. a duration), matching the sleep-stage list.
//
// Tokens only (no hardcoded hex), light/dark safe (the hatch reads on both), VoiceOver-summarised.

// MARK: - Diagonal hatch shape

/// A field of parallel 45° diagonal lines clipped to the shape's rect — the "typical range" texture.
/// Spacing/inset are in points so the hatch density stays constant regardless of bar width.
public struct DiagonalHatch: Shape {
    /// Gap between hatch lines, in points.
    public var spacing: CGFloat
    public init(spacing: CGFloat = 5) { self.spacing = spacing }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0, spacing > 0 else { return path }
        // Draw lines running bottom-left → top-right (45°). Start far enough left that the slanted
        // lines still cover the full rect after the diagonal offset, then clip to the rect.
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

// MARK: - TypicalRangeBar

public struct TypicalRangeBar: View {

    /// The user's value as a 0…1 fraction of the bar's full width (clamped).
    public var value: Double
    /// The typical / reference range as 0…1 fractions (lower…upper) of the bar (clamped, ordered).
    /// nil = no range → the value fill sits over a plain inset track (no hatch).
    public var typical: ClosedRange<Double>?
    /// The solid fill colour for the user's value (the domain / stage / status token).
    public var color: Color
    /// Bar height. Kept short so it reads as a row element.
    public var height: CGFloat
    /// Corner radius of the bar; defaults to fully-rounded for the WHOOP pill look.
    public var cornerRadius: CGFloat?

    public init(
        value: Double,
        typical: ClosedRange<Double>? = nil,
        color: Color,
        height: CGFloat = 8,
        cornerRadius: CGFloat? = nil
    ) {
        self.value = value
        self.typical = typical
        self.color = color
        self.height = height
        self.cornerRadius = cornerRadius
    }

    private var clampedValue: Double { min(max(value, 0), 1) }

    /// The typical range clamped to 0…1 and ordered low→high, or nil.
    private var clampedTypical: ClosedRange<Double>? {
        guard let t = typical else { return nil }
        let lo = min(max(t.lowerBound, 0), 1)
        let hi = min(max(t.upperBound, 0), 1)
        return lo <= hi ? lo...hi : hi...lo
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let radius = cornerRadius ?? h / 2
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            ZStack(alignment: .leading) {
                // Base track — the inset "well" the bar sits in.
                shape.fill(StrandPalette.surfaceInset)

                // Diagonal-hatch "typical range" segment (only over the range span).
                if let t = clampedTypical, t.upperBound > t.lowerBound {
                    let x = w * CGFloat(t.lowerBound)
                    let segWidth = w * CGFloat(t.upperBound - t.lowerBound)
                    DiagonalHatch(spacing: 5)
                        .stroke(StrandPalette.textTertiary.opacity(0.55), lineWidth: 1)
                        .frame(width: segWidth, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: min(radius, segWidth / 2), style: .continuous))
                        .offset(x: x)
                        .accessibilityHidden(true)
                }

                // Solid value fill — "you". Flat + crisp, no glow.
                shape
                    .fill(color)
                    .frame(width: max(h, w * CGFloat(clampedValue)))
            }
            .clipShape(shape)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axLabel))
    }

    private var axLabel: String {
        let pct = Int((clampedValue * 100).rounded())
        if let t = clampedTypical {
            let lo = Int((t.lowerBound * 100).rounded())
            let hi = Int((t.upperBound * 100).rounded())
            let placement = clampedValue < t.lowerBound ? "below" : (clampedValue > t.upperBound ? "above" : "within")
            return "\(pct) percent, \(placement) the typical range of \(lo) to \(hi) percent"
        }
        return "\(pct) percent"
    }
}

// MARK: - TypicalRangeRow (full WHOOP detail row)

/// One WHOOP-style range row: a leading colour swatch, an UPPERCASE label, the value tinted to the
/// stage/domain colour, the hatched range bar, and a right-aligned WHITE trailing string (e.g. a
/// duration like "1:24"). Mirrors WHOOP's sleep-stage breakdown rows.
public struct TypicalRangeRow: View {

    /// UPPERCASE label (e.g. "DEEP", "REM", "HRV").
    public var label: String
    /// The coloured value string shown next to the label (e.g. "18%"). nil hides it.
    public var valueText: String?
    /// Right-aligned white trailing string (e.g. a duration "1:24" or "62 ms"). nil hides it.
    public var trailingText: String?
    /// The user's value 0…1 fraction for the bar.
    public var value: Double
    /// The typical range 0…1, or nil for no hatch.
    public var typical: ClosedRange<Double>?
    /// The stage / domain colour (swatch, value tint, value fill).
    public var color: Color

    public init(
        label: String,
        valueText: String? = nil,
        trailingText: String? = nil,
        value: Double,
        typical: ClosedRange<Double>? = nil,
        color: Color
    ) {
        self.label = label
        self.valueText = valueText
        self.trailingText = trailingText
        self.value = value
        self.typical = typical
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Colour swatch.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

            // Label + coloured value.
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let valueText {
                    Text(valueText)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(color)
                }
            }
            .frame(width: 96, alignment: .leading)

            // The hatched range bar.
            TypicalRangeBar(value: value, typical: typical, color: color)

            // Right-aligned WHITE trailing (duration / raw value).
            if let trailingText {
                Text(trailingText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axLabel))
    }

    private var axLabel: String {
        var parts: [String] = [label]
        if let valueText { parts.append(valueText) }
        if let trailingText { parts.append(trailingText) }
        let base = parts.joined(separator: ", ")
        guard let t = typical else { return base }
        let v = min(max(value, 0), 1)
        let placement = v < t.lowerBound ? "below typical" : (v > t.upperBound ? "above typical" : "within typical range")
        return "\(base), \(placement)"
    }
}

#if DEBUG
#Preview("TypicalRangeBar / Row") {
    VStack(alignment: .leading, spacing: 16) {
        Text("Sleep stages").strandOverline()
        VStack(spacing: 10) {
            TypicalRangeRow(label: "Awake", valueText: "4%", trailingText: "0:18",
                            value: 0.04, typical: 0.02...0.10, color: StrandPalette.sleepAwake)
            TypicalRangeRow(label: "Light", valueText: "52%", trailingText: "4:02",
                            value: 0.52, typical: 0.45...0.60, color: StrandPalette.sleepLight)
            TypicalRangeRow(label: "Deep", valueText: "18%", trailingText: "1:24",
                            value: 0.18, typical: 0.12...0.23, color: StrandPalette.sleepDeep)
            TypicalRangeRow(label: "REM", valueText: "26%", trailingText: "2:01",
                            value: 0.26, typical: 0.18...0.25, color: StrandPalette.sleepREM)
        }

        Text("Bar only").strandOverline().padding(.top, 8)
        TypicalRangeBar(value: 0.72, typical: 0.40...0.65, color: StrandPalette.statusPositive)
            .frame(width: 240)
        TypicalRangeBar(value: 0.30, color: StrandPalette.accent)
            .frame(width: 240)
    }
    .padding(28)
    .frame(width: 520, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
