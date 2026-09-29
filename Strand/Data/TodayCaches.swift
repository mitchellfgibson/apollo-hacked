import Foundation
import WhoopStore    // WorkoutRow, AppleDaily, CachedSleepSession
import StrandDesign  // TrendPoint

// MARK: - Today snapshot caches
//
// Upstream declares these two snapshot types INSIDE its own `TodayView.swift`. This fork keeps its
// own Today screen, so they live here instead: `Repository` holds both as long-lived properties
// (see `todayHistoryWideCache` / `todayDayScopedCache`) and that storage must exist regardless of
// which Today screen is mounted. This fork's Today does not populate them yet, so they simply stay
// nil — the Repository API, and every upstream consumer that reads it, still compiles unchanged.


/// #849: an in-memory snapshot of everything `loadHistoryWide()` computes: the ~40 history-wide reads +
/// the per-workout strap-HR derivation. Held on the long-lived `Repository` (NOT TodayView's `@State`),
/// keyed by the `refreshSeq` it was built at, so a Today RE-MOUNT (TabView/module switch, or an
/// Apple-Health import that recreates the view, both tear down `@State`) can RESTORE these values without
/// re-running the heavy query pass. Restoring is a handful of in-memory assignments; the old code instead
/// re-ran the full history-wide reload on every re-mount, which is the lag #849 reports returning to Today
/// after an import. Built only after a real `loadHistoryWide()`; consumed when the seq still matches.
struct TodayHistoryWideCache {
    let sparks: [String: [Double]]
    let stepsEstByDay: [String: Int]
    let workouts: [WorkoutRow]
    let appleDays: [AppleDaily]
    let xiaomiDays: Int
    let xiaomiSleeps: Int
    let stressToday: Double?
    let fitnessAgeToday: Double?
    let vo2maxToday: Double?
    let vitalityToday: Double?
    // Hydration total/goal intentionally absent (#989): mutations don't bump refreshSeq, so a cached
    // value could restore stale. TodayView re-reads hydration live on restore instead.
}

/// #849/#932: an in-memory snapshot of everything `loadDayScoped()` computes for ONE viewed day: the Rest
/// score + its tile spark, the provenance winners, the selected day's 5-minute HR buckets, the day's step
/// activity class, the live Effort, the pinned chart axis and the overlapping sleep band. Held on the
/// long-lived `Repository` (NOT TodayView's `@State`), keyed by the (`refreshSeq`, viewed-day key) it was
/// built at, so a Today RE-MOUNT with unchanged data (macOS cold-mounts the screen on every sidebar switch)
/// can RESTORE these values without re-running the heavy `hrBuckets`/`hrSamples` reads, 170k+ HR rows/day
/// on a big library, the measured #932 frame degradation. The day key half of the pair is what makes day
/// navigation safe: another day's snapshot can never be served because its key differs. Built only after a
/// real `loadDayScoped()`; consumed when BOTH the seq AND the day key still match (see
/// `Repository.todayDayScopedLoadedSeq` / `todayDayScopedLoadedDayKey`).
struct TodayDayScopedCache {
    let restSpark: [Double]
    let restScore: Double?
    let provenanceByMetric: [String: String]
    let providerByMetric: [String: ScoreInputProvider]
    let hrPoints: [TrendPoint]
    let stepActivityClassToday: Int?
    let liveTodayStrain: Double?
    let hrAxis: ClosedRange<Date>
    let sleepToday: CachedSleepSession?
    /// When the snapshot was banked. TODAY hits are age-gated on this (`todayCacheMaxAge`): live banking
    /// does not bump `refreshSeq`, so an unbounded today snapshot would drift behind the 1Hz stream.
    let bankedAt: Date
}
