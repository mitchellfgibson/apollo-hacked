import Foundation

// HydrationGoal.swift — pure daily hydration goal math for the opt-in Hydration tracker (MVP).
//
// LOCAL-ONLY, OPT-IN, MANUAL-FIRST: the user logs water with quick taps; this enum computes the day's
// target in ml. It is a plain, transparent guide built from a sex baseline plus a small bump scaled by
// the day's Effort (strain) — NEVER medical advice and never an invented measurement. The whole formula
// lives here so it is headless and unit-tested, and is BYTE-IDENTICAL to the Android twin
// (com.noop.analytics.HydrationGoal): same Int constants, same round-then-clamp, same integer rounding.
// Do not change a constant or a rule on one platform without the other.
//
//   GOAL(ml) = roundToNearest( sexBaseline + effortBump, 50 )
//     sexBaseline : male 3700, female 2700, unspecified/other 3200 ml
//     effortBump  : clamp(round(effort/100 · 700), 0…700); 0 when no Effort is available
//
// `effort` is the day's Effort/strain score on NOOP's native 0…100 scale (the value stored as
// `DailyMetric.strain`). The bump is intentionally modest (≤ 0.7 L) so a hard day nudges the target up
// without ever turning the guide into a hard rule.
public enum HydrationGoal {

    // MARK: - Constants (mirror these EXACTLY in the Android twin — they are Int there)

    /// Baseline target by sex, in millilitres, before the Effort bump.
    public static let baselineMaleML = 3700
    public static let baselineFemaleML = 2700
    /// Used for "unspecified" / "other" / any unrecognised sex token.
    public static let baselineOtherML = 3200

    /// The most the Effort bump can add (ml) — reached at Effort 100.
    public static let maxEffortBumpML = 700

    /// The goal is rounded to the nearest multiple of this (ml) for a clean read-out.
    public static let roundToML = 50

    // MARK: - Quick-log amounts (ml) — the three tap sizes

    public static let sipML = 30
    public static let cupML = 237     // a US cup (8 fl oz)
    public static let bottleML = 500  // a standard small water bottle

    // MARK: - Pieces (each pure + independently testable; mirror the Kotlin twin)

    /// Baseline ml for a sex token. Case- and whitespace-insensitive; "male"/"m" and "female"/"f" map to
    /// their baselines, anything else ("nonbinary", "other", "", unknown) maps to the unspecified baseline
    /// — we never guess a sex we weren't given.
    public static func baselineForSex(_ sex: String) -> Int {
        switch sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "male", "m":   return baselineMaleML
        case "female", "f": return baselineFemaleML
        default:            return baselineOtherML
        }
    }

    /// The Effort bump (ml) for a day's Effort score on the 0…100 scale: `round(effort/100 · 700)` then
    /// clamped to 0…700. `effort == nil` (no Effort yet today) yields 0 — never a fabricated bump. Rounds
    /// FIRST then clamps the OUTPUT (matching the Kotlin twin), so an out-of-range input can't blow past
    /// the cap. A non-finite effort is treated as "no Effort" (0).
    public static func effortBump(effort: Double?) -> Int {
        guard let effort, effort.isFinite else { return 0 }
        let raw = Int((effort / 100.0 * Double(maxEffortBumpML)).rounded())
        return min(maxEffortBumpML, max(0, raw))
    }

    /// Round `value` to the nearest multiple of `step` (step > 0). Half rounds up — `((value + step/2) /
    /// step) * step` on non-negative ints — matching the Kotlin twin and Swift's away-from-zero rounding.
    public static func roundToNearest(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return ((value + step / 2) / step) * step
    }

    // MARK: - The goal

    /// The day's hydration goal in ml: `roundToNearest(sexBaseline + effortBump, 50)`. Pure — feed it the
    /// profile sex token and the day's Effort score (or nil). The result is always a multiple of 50.
    public static func dailyGoalML(sex: String, effort: Double?) -> Int {
        roundToNearest(baselineForSex(sex) + effortBump(effort: effort), step: roundToML)
    }

    // MARK: - Display helpers

    /// Litres (ml / 1000) for the litre read-outs.
    public static func litres(fromML ml: Double) -> Double { ml / 1000.0 }

    /// "<total> / <goal> L" in litres to 1 dp, e.g. "1.2 / 3.2 L" — the dashboard card value, fixed-locale
    /// so the string is byte-identical to the Android twin (`String.format(Locale.US, "%.1f / %.1f L")`).
    public static func cardValueString(totalML: Double, goalML: Int) -> String {
        String(format: "%.1f / %.1f L", litres(fromML: totalML), litres(fromML: Double(goalML)))
    }

    /// Fraction of the goal met (0…1, clamped) for the progress ring.
    public static func fraction(totalML: Double, goalML: Int) -> Double {
        guard goalML > 0 else { return 0 }
        return min(1.0, max(0.0, totalML / Double(goalML)))
    }
}
