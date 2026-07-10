import SwiftUI

// MARK: - Hex Color Helper

public extension Color {
    /// Create a Color from a hex string like "#0B0D12" or "0B0D12" (RGB) or "#AARRGGBB" / "RRGGBBAA".
    /// Supported lengths: 6 (RGB), 8 (RGBA).
    init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&int)
        let r, g, b, a: Double
        switch raw.count {
        case 8: // RRGGBBAA
            r = Double((int >> 24) & 0xFF) / 255.0
            g = Double((int >> 16) & 0xFF) / 255.0
            b = Double((int >> 8) & 0xFF) / 255.0
            a = Double(int & 0xFF) / 255.0
        default: // RRGGBB (6) and any fallback
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Strand Palette
//
// Every semantic token from design spec §9.1. LIGHT theme (chrome inverted from the
// original near-black instrument palette): white surfaces, near-black text. The DATA
// colors below (recovery / strain / sleep / HR-zone / status / metric accents) are
// intentionally left at their original values so the recovery & strain color language
// is preserved on the light background.

public enum StrandPalette {

    // MARK: Surfaces (§9.1) — light theme
    public static let surfaceBase    = Color(hex: "#FFFFFF") // page background — white
    public static let surfaceRaised  = Color(hex: "#F4F6F5") // cards — faint grey
    public static let surfaceOverlay = Color(hex: "#EAEEEC") // popovers / sheets
    public static let surfaceInset   = Color(hex: "#F7F9F8") // wells / chart insets
    public static let hairline       = Color(hex: "#DCE2DF") // soft 1px border
    public static let hairlineStrong = Color(hex: "#C3CCC7") // hover / emphasis border

    // MARK: Text (§9.1) — near-black on white
    public static let textPrimary    = Color(hex: "#0A0C0B")
    public static let textSecondary  = Color(hex: "#525C57")
    public static let textTertiary   = Color(hex: "#7A847F")

    // MARK: Glow (§9.1) — kept as a soft tint (unused as page bg now)
    public static let glowAmbient    = Color(hex: "#D6E2EC")

    // MARK: Accent — chrome, not data (§9.1)
    public static let accent         = Color(hex: "#18C98B") // health green (brief)
    public static let accentHover    = Color(hex: "#2FE0A0")
    public static let accentMuted    = Color(hex: "#D8F2E7") // light-green tint (selected rows)
    /// Focus ring color (same as accent).
    public static let focusRing      = Color(hex: "#18C98B")
    /// Opacity for dimmed/disabled sections (shared so screens don't invent their own value).
    public static let disabledOpacity: Double = 0.45

    // MARK: Recovery gradient — vitaltrends-style traffic light (low red → high green).
    // 0.00 red → 0.30 amber → 0.55 gold → 0.78 green → 1.00 emerald-mint.
    public static let recovery000 = Color(hex: "#FF4F73") // depleted — pink-red (brief)
    public static let recovery030 = Color(hex: "#F5A623") // low — amber
    public static let recovery055 = Color(hex: "#E8C24B") // moderate — gold
    public static let recovery078 = Color(hex: "#18C98B") // primed — health green
    public static let recovery100 = Color(hex: "#2FE6A8") // peak — bright green

    /// Ordered gradient stops for the recovery scale (location + color).
    public static let recoveryStops: [Gradient.Stop] = [
        .init(color: recovery000, location: 0.00),
        .init(color: recovery030, location: 0.30),
        .init(color: recovery055, location: 0.55),
        .init(color: recovery078, location: 0.78),
        .init(color: recovery100, location: 1.00),
    ]

    /// The signature recovery gradient (indigo → mint).
    public static let recoveryGradient = Gradient(stops: recoveryStops)

    // MARK: Strain ramp — ember → magenta (§9.1)
    public static let strain000 = Color(hex: "#E8B04B") // ember / warm gold
    public static let strain033 = Color(hex: "#E8743B") // orange
    public static let strain066 = Color(hex: "#E0476B") // rose-red
    public static let strain100 = Color(hex: "#C13AC1") // magenta

    public static let strainStops: [Gradient.Stop] = [
        .init(color: strain000, location: 0.00),
        .init(color: strain033, location: 0.33),
        .init(color: strain066, location: 0.66),
        .init(color: strain100, location: 1.00),
    ]

    /// The strain gradient (output / heat).
    public static let strainGradient = Gradient(stops: strainStops)

    // MARK: Sleep stages (§9.1)
    public static let sleepAwake = Color(hex: "#E0476B") // rose
    public static let sleepLight = Color(hex: "#5C6FB1") // periwinkle
    public static let sleepDeep  = Color(hex: "#2C3A7A") // deep indigo
    public static let sleepREM   = Color(hex: "#5BE0C7") // mint (glows)

    // MARK: HR zones (§9.1)
    public static let zone1 = Color(hex: "#4FA9C9")
    public static let zone2 = Color(hex: "#5BD3A0")
    public static let zone3 = Color(hex: "#E8C24B")
    public static let zone4 = Color(hex: "#E8743B")
    public static let zone5 = Color(hex: "#E0476B")

    /// HR zones indexed 1...5; index 0 mirrors zone1 for convenience.
    public static let hrZones: [Color] = [zone1, zone1, zone2, zone3, zone4, zone5]

    // MARK: Status (§9.1) — never reused as recovery colors.
    public static let statusPositive = Color(hex: "#18C98B")
    public static let statusWarning  = Color(hex: "#F5A623")
    public static let statusCritical = Color(hex: "#FF4F73")

    // MARK: Per-metric accents (brief) — Apple-Health bars / HRV / energy / risk.
    public static let metricCyan   = Color(hex: "#2FC7FF") // Apple Health bars
    public static let metricPurple = Color(hex: "#A879FF") // HRV / strain-style data
    public static let metricAmber  = Color(hex: "#F5A623") // calories / moderate
    public static let metricRose   = Color(hex: "#FF4F73") // risk / high strain / low recovery

    // MARK: - Sampling helpers

    /// Sample the recovery gradient (indigo → mint) at a recovery score 0...100.
    /// Returns the exact interpolated color used everywhere recovery is tinted.
    public static func recoveryColor(_ score: Double) -> Color {
        sample(stops: recoveryStops, at: score / 100.0)
    }

    /// Sample the strain gradient at a strain value on the 0...21 Whoop scale.
    public static func strainColor(_ strain: Double) -> Color {
        sample(stops: strainStops, at: strain / 21.0)
    }

    /// The state word for a recovery score, per spec §9.3.
    /// DEPLETED · LOW · MODERATE · PRIMED · PEAK
    public static func recoveryState(_ score: Double) -> String {
        switch score {
        case ..<25:  return "DEPLETED"
        case ..<50:  return "LOW"
        case ..<70:  return "MODERATE"
        case ..<88:  return "PRIMED"
        default:     return "PEAK"
        }
    }

    /// HR-zone color for a 0...5 zone index (clamped).
    public static func hrZoneColor(_ zone: Int) -> Color {
        let z = max(1, min(5, zone))
        return hrZones[z]
    }

    /// Color for a sleep stage by canonical name (awake/light/deep/rem).
    public static func sleepStageColor(_ stage: SleepStage) -> Color {
        switch stage {
        case .awake: return sleepAwake
        case .light: return sleepLight
        case .deep:  return sleepDeep
        case .rem:   return sleepREM
        }
    }

    // MARK: - Linear gradient stop interpolation

    /// Interpolate a set of gradient stops at a normalized position 0...1.
    /// Clamps out-of-range positions to the end stops.
    public static func sample(stops: [Gradient.Stop], at position: Double) -> Color {
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        let t = min(max(position, 0.0), 1.0)

        // Find the bracketing pair.
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if t >= a.location && t <= b.location {
                lower = a
                upper = b
                break
            }
        }
        let span = upper.location - lower.location
        let localT = span > 0 ? (t - lower.location) / span : 0
        return interpolate(lower.color, upper.color, localT)
    }

    /// Linear-interpolate two colors in sRGB space.
    static func interpolate(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ca = a.rgbaComponents
        let cb = b.rgbaComponents
        let tt = min(max(t, 0.0), 1.0)
        return Color(
            .sRGB,
            red:   ca.r + (cb.r - ca.r) * tt,
            green: ca.g + (cb.g - ca.g) * tt,
            blue:  ca.b + (cb.b - ca.b) * tt,
            opacity: ca.a + (cb.a - ca.a) * tt
        )
    }
}

// MARK: - Sleep stage enum (shared with Hypnogram)

public enum SleepStage: String, CaseIterable, Sendable {
    case awake
    case light
    case deep
    case rem

    /// Display label.
    public var label: String {
        switch self {
        case .awake: return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }

    /// Vertical band order (top = awake, bottom = deep) for hypnogram layout.
    public var bandRank: Int {
        switch self {
        case .awake: return 0
        case .rem:   return 1
        case .light: return 2
        case .deep:  return 3
        }
    }
}

// MARK: - Color component extraction

extension Color {
    /// Resolve to sRGB RGBA components in 0...1. Works on macOS 13+ via platform color bridge.
    var rgbaComponents: (r: Double, g: Double, b: Double, a: Double) {
        #if canImport(AppKit)
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(UIKit)
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #else
        return (0, 0, 0, 1)
        #endif
    }
}

#if DEBUG
#Preview("Palette") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            swatchRow("Surfaces", [
                ("base", StrandPalette.surfaceBase),
                ("raised", StrandPalette.surfaceRaised),
                ("overlay", StrandPalette.surfaceOverlay),
                ("inset", StrandPalette.surfaceInset),
                ("hairline", StrandPalette.hairline),
                ("hairline.strong", StrandPalette.hairlineStrong),
            ])
            swatchRow("Text", [
                ("primary", StrandPalette.textPrimary),
                ("secondary", StrandPalette.textSecondary),
                ("tertiary", StrandPalette.textTertiary),
            ])
            swatchRow("Accent", [
                ("accent", StrandPalette.accent),
                ("hover", StrandPalette.accentHover),
                ("muted", StrandPalette.accentMuted),
            ])
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY GRADIENT").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.recoveryGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("STRAIN RAMP").font(.caption).foregroundStyle(StrandPalette.textTertiary)
                LinearGradient(gradient: StrandPalette.strainGradient, startPoint: .leading, endPoint: .trailing)
                    .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            swatchRow("Sleep stages", [
                ("awake", StrandPalette.sleepAwake),
                ("light", StrandPalette.sleepLight),
                ("deep", StrandPalette.sleepDeep),
                ("REM", StrandPalette.sleepREM),
            ])
            swatchRow("HR zones", [
                ("Z1", StrandPalette.zone1), ("Z2", StrandPalette.zone2),
                ("Z3", StrandPalette.zone3), ("Z4", StrandPalette.zone4),
                ("Z5", StrandPalette.zone5),
            ])
        }
        .padding(24)
    }
    .frame(width: 520, height: 760)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.light)
}

@ViewBuilder
private func swatchRow(_ title: String, _ items: [(String, Color)]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title.uppercased())
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        HStack(spacing: 10) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color)
                        .frame(width: 64, height: 48)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StrandPalette.hairline, lineWidth: 1))
                    Text(name).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
