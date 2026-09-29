import SwiftUI
import Charts
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign

// MARK: - TodayView statics carried from upstream
//
// Upstream declares these as statics on ITS `TodayView`. This fork keeps its own Today screen, but
// `LiquidTodayView` and the hosted cards still call them through `TodayView.…`, so they are carried
// here verbatim as an extension. Pure projections over stored values — no view state — which is why
// they move cleanly. `private` is dropped where upstream had it, because the callers now live in a
// different file.

extension TodayView {

    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }

    static func make(from workout: AppModel.ActiveWorkout?) -> ActiveWorkoutIndicatorModel? {
        guard let workout else { return nil }
        return ActiveWorkoutIndicatorModel(sport: workout.sport, startedAt: workout.start,
                                           pausedAt: workout.pausedAt,
                                           pausedDuration: workout.pausedDuration)
    }

    /// Elapsed ACTIVE time, formatted M:SS up to an hour and H:MM:SS once an hour has passed (so a
    /// 90-minute session reads "1:30:00", not "90:00"). Clamped at zero so a clock-skew negative reads 0:00.
    /// Pure + injectable `now` for deterministic tests. (StrandFont.bodyNumber already applies tabular figures,
    /// so the call site does NOT add `.monospacedDigit()`.)
    ///
    /// `pausedAt`/`pausedDuration` default to "never paused" so the existing call sites and tests that
    /// predate pause keep their exact meaning; the math itself lives in `ActiveWorkoutClock`.
    static func elapsed(since start: Date, pausedAt: Date? = nil, pausedDuration: TimeInterval = 0,
                        now: Date = Date()) -> String {
        ActiveWorkoutClock.clock(Int(ActiveWorkoutClock.activeElapsed(
            start: start, pausedAt: pausedAt, pausedDuration: pausedDuration, now: now)))
    }

    /// Product mark, never natural-language copy. Keeping it out of localization also makes source
    /// classification and tint selection stable when the app language changes.
    static let whoopBrandName = "WHOOP"

    static let guideCardSeenKey = "scoringGuideCardSeen"

    /// #860 item 1: the launch day-landing policy, as ONE pure decision so the rule can't drift between the
    /// view and its test and stays byte-identical to the Kotlin twin. A FRESH-PROCESS launch ALWAYS lands on
    /// today (offset 0), even when today has no data yet and the only banked data is N days back (that exact
    /// case is what stranded a calibrating user on an old day after an app update, the reporter's case). A
    /// non-fresh (in-session) call returns `savedOffset` UNCHANGED, so tabbing away to an old day and coming
    /// back within the same process preserves the user-navigated day (#739/#614). `hasTodayData` and
    /// `latestDataDayBack` are accepted so the signature documents the inputs the retired auto-land consumed,
    /// but on a fresh launch they intentionally have NO effect: the old "land on the most recent data day"
    /// behaviour (#605/#739) is retired. Mirror EXACTLY in Kotlin.
    static func launchDayOffset(isFreshLaunch: Bool,
                                savedOffset: Int,
                                hasTodayData: Bool,
                                latestDataDayBack: Int) -> Int {
        // Fresh process: snap to today unconditionally. The data-shape inputs are deliberately ignored so a
        // calibrating user whose newest data is days back still opens on today, not on that old day.
        guard isFreshLaunch else { return savedOffset }
        return 0
    }

    /// Dashboard-card placeholder for a baseline-relative metric (Stress) still seeding its window, an
    /// honest "building your baseline" state rather than a bare dash (#706/#684). Rendered dimmed.
    /// Localized: it shows in the card value slot, and the dimming check compares against this same
    /// constant, so localizing both sides keeps the placeholder/real-value distinction intact.
    static let calibratingPlaceholder = String(localized: "Calibrating")

    /// The number of Key-Metric tiles shown before the "Show all metrics" expander (S5). Two columns, so
    /// six fills three clean rows; the rest fold behind the expander. Static so the cap is unit-testable.
    static let metricsCollapsedCap = 6

    /// Pure carry-over selector behind `lastScoredRecoveryDay`, extracted so the gate + selection can be
    /// unit-tested without a live view (mirrors `buildingHintCopy` / the Android `lastScoredRecoveryDay`).
    /// Returns the freshest scored prior row to carry over, or nil. `days` is oldest→newest; the chosen
    /// row is the last with a non-nil recovery that ISN'T today's (still-nil) key. nil unless: it's today,
    /// today itself isn't scored, and we're not mid-calibration (calibration owns its own copy), so past
    /// days / a scored today / a calibrating today all carry nothing and live behaviour is unchanged.
    static func lastScoredRecoveryDay(days: [DailyMetric], selectedDayKey: String,
                                      isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        // Defensive future-day guard (#547): the carry-over must NEVER select a day after today's key, or a
        // stray future-dated row (a bad-clock strap that slipped past the ingest gate / pre-heal DB) would
        // surface as "last night · 12 Jul". `selectedDayKey` is today's logical-day key here (isToday), and
        // yyyy-MM-dd compares lexicographically, so `$0.day < selectedDayKey` keeps only genuine prior days.
        // Belt-and-suspenders on top of the gate + one-time heal, cheap and never wrong.
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }

    /// #817 - day-nav swipe/arrow clamp. Pure + unit-testable so the bounds can't drift between the
    /// swipe gesture, the chevrons and the date jump. `current` is the days-back offset (0 = today),
    /// `delta` is +1 to step one day OLDER, -1 to step one day NEWER. The result is clamped to
    /// `0 ... maxOffset`: never past today (no future day), never older than the earliest data day.
    /// `maxOffset` is the number of whole days from today's logical day back to the earliest banked day
    /// (0 when there's no data yet, so the only reachable day is today). Mirror EXACTLY in Kotlin.
    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        let upper = max(0, maxOffset)
        return min(upper, max(0, current + delta))
    }

    /// #2378 - the day step a horizontal swipe of `dx` points asks for: +1 OLDER, -1 NEWER.
    ///
    /// Rightward (dx > 0) is OLDER and leftward is NEWER, which is direct manipulation — dragging the
    /// content left brings the page to its right, the later day, into view — and the direction the
    /// Kotlin twin already takes (`dayNavSwipeTarget`, pinned by `DayNavTest`). Apple ran the opposite
    /// way in both shells, so the same gesture moved the day backwards here and forwards there.
    ///
    /// Pure and shared by both Apple shells so the direction is pinned by a test rather than living
    /// twice inside gesture closures, which is how the two platforms drifted apart unnoticed.
    /// Mirror EXACTLY in Kotlin.
    static func daySwipeDelta(dx: CGFloat) -> Int {
        dx > 0 ? 1 : -1
    }

    /// #16 - whole days-back offset for a date chosen in the day-nav picker, measured from the LOGICAL day
    /// (not raw Date()). Pure + unit-testable so the 00:00-04:00 rollover case is locked: in that window the
    /// logical day is the PREVIOUS calendar day, so anchoring the offset here (rather than on raw Date())
    /// keeps the picked day in step with the visible date and the a11y label. Clamped at 0 so a future-
    /// relative pick collapses to today. Both dates are reduced to their start-of-day before counting.
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }

    /// Whole days from today's logical day back to `earliestDayKey` (the oldest banked day across all
    /// sources). nil/unparseable earliest, or a key on/after today, both yield 0 - today is then the only
    /// navigable day. Both keys are "yyyy-MM-dd". Pure + unit-testable.
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }

    /// Carry-over recency cap (#779): the "Last night" framing only holds when the carried scored day is
    /// within this many days of today. A weeks-old import is still carried so the recovery side isn't a bare
    /// blank, but it is relabelled "Latest sleep · <date>" so a stale number is NEVER passed off as today's.
    static let carryFreshnessDays = 2

    /// True when the carried scored day is OLDER than the freshness cap (#779), which drives the "Latest
    /// sleep" relabel. Pure + unit-testable. Both keys are "yyyy-MM-dd"; an unparseable key (or non-positive gap)
    /// reads as fresh so we never over-claim staleness. `todayKey` is today's logical-day key (carry-over is
    /// today-only). Mirror EXACTLY in Kotlin.
    static func isCarryStale(priorDayKey: String, todayKey: String) -> Bool {
        guard let prior = dayKeyParser.date(from: priorDayKey),
              let today = dayKeyParser.date(from: todayKey) else { return false }
        let days = Calendar.current.dateComponents([.day], from: prior, to: today).day ?? 0
        return days > carryFreshnessDays
    }

    /// #977 — HONEST Rest resolution for the selected day. Today's own scored Rest wins; otherwise, ONLY on
    /// today, tail-fall-back to the last scored night — but ONLY when that night is within the carry-freshness
    /// window (`isCarryStale == false`). A live 5.0 whose sleep never scores (no overnight gravity ⇒ no
    /// `sleep_performance` point ever written) used to pin Rest to a weeks-old scored night while Charge kept
    /// advancing; gating the tail-fallback lets the Rest hero fall through to its No-Data/calibrating state
    /// instead of freezing on a stale number. The legitimate morning carry of last night's Rest (before today
    /// scores) is preserved unchanged. Pure + unit-testable. Mirror EXACTLY in Kotlin.
    static func freshRestScore(todayValue: Double?, lastDay: String?, lastValue: Double?,
                               isTodaySelected: Bool, todayKey: String) -> Double? {
        if let v = todayValue { return v }
        guard isTodaySelected, let lastDay, let lastValue,
              !isCarryStale(priorDayKey: lastDay, todayKey: todayKey) else { return nil }
        return lastValue
    }

    /// #1164/#2012 — should today's Rest be MARKED provisional? When the strap has banked records not yet
    /// offloaded, the Rest score is computed from partial data and may change once the full night lands and
    /// `analyzeRecent` re-scores it. Saying so reads honestly instead of as a bug when the number moves.
    ///
    /// True means "caption it as pending", NOT "hide it". #2012: the number used to be withheld on both
    /// surfaces while this was true, so a user whose night was scored saw nothing for as long as the strap
    /// had anything left to send, which on a continuously banking strap is most of the day. A number that
    /// may still move is not the same as no number, and it is the one the screen exists to show.
    ///
    /// Two honest signals, either of which means more data is expected:
    /// - `backfilling`: an offload is actively running right now (data is draining).
    /// - `historyPendingSync`: the strap reports banked records newer than our local frontier (the strap
    ///   has data we haven't ingested yet, even when no offload is running — e.g. right after connect,
    ///   before the first offload starts).
    ///
    /// Only applies to TODAY (a past day's score is final — no more data is coming for it) and only when a
    /// Rest score EXISTS (pending annotates a score; it never fabricates one where there is none). Pure +
    /// unit-testable. Mirror EXACTLY in Kotlin.
    static func restPendingSync(restScore: Double?, backfilling: Bool,
                                historyPendingSync: Bool, isTodaySelected: Bool) -> Bool {
        guard isTodaySelected, restScore != nil else { return false }
        return backfilling || historyPendingSync
    }

    /// The carried recovery caption stamp, keyed on that scored day's own date and its recency. Within the
    /// freshness cap it reads "Last night · <date>"; once the carried day is older than the cap (#779) it
    /// reads "Latest sleep · <date>" so a weeks-old import is never surfaced as "Last night". Shared by every
    /// carried recovery read-out so the prior-day provenance reads identically. Mirror EXACTLY in Kotlin.
    static func carriedCaption(priorDayKey: String, todayKey: String) -> String {
        let date = lastChargeDateFmt(priorDayKey)
        return isCarryStale(priorDayKey: priorDayKey, todayKey: todayKey)
            ? String(localized: "Latest sleep · \(date)")
            : String(localized: "Last night · \(date)")
    }

    /// #205 (one-word readiness read kept on the hero: Push / Maintain / Rest). PURE mapping of the
    /// existing `ReadinessEngine.Level` so the hero keeps a glanceable verdict even though the full
    /// Readiness card folds into the Charge breakdown sheet (S4). `insufficient` returns nil (the hero then
    /// shows no readiness word, matching the old card hiding itself). Mirror EXACTLY in Kotlin.
    static func readinessWord(_ level: ReadinessEngine.Level) -> String? {
        switch level {
        case .primed:       return String(localized: "Push")
        case .balanced:     return String(localized: "Maintain")
        case .strained:     return String(localized: "Rest")
        case .rundown:      return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    /// The strap's live recording state, mapped from the connection, the live heart-rate sample, and the
    /// last-sync timestamp. Only TODAY carries a recording chip (a navigated past day isn't "recording
    /// now"), so this returns the honest state at offset 0 and `nil` otherwise (the chip then isn't
    /// rendered). "Recording" requires BOTH a live connection AND a current live HR sample, so a connected
    /// strap that isn't yet streaming HR reads as a last-sync / not-recording state, not a false "Recording".
    /// Resolves the recording state for the selected day from a `LiveState` snapshot. Takes `live` as a
    /// parameter rather than reading `self.live` so TodayView itself doesn't observe `LiveState` (see the
    /// PERF note on the missing `@EnvironmentObject live`); the small `RecordingStatusLight` subview that
    /// DOES observe `live` calls this. Past days aren't "recording", so it's nil off offset 0.
    static func recordingState(live: LiveState, selectedDayOffset: Int) -> RecordingState? {
        guard selectedDayOffset == 0 else { return nil }
        // #580, a connected WHOOP 5/MG streaming live HR but offloading no history reads "Connected,         // history sync is experimental on 5.0" rather than a WHOOP-4-style "not recording"/sync-error.
        // BLEManager only flips this true while connected + streaming, so it overrides the honest mapper.
        if live.connected && live.historySyncExperimental { return .historyExperimental }
        return RecordingState.resolve(connected: live.connected,
                                      heartRate: live.heartRate,
                                      lastSyncedAt: live.lastSyncedAt,
                                      sustainedEmptyOffload: live.sustainedEmptyOffload)
    }

    /// PURE mapper (unit-testable), a raw resolver source id onto the spec's provenance labels, given
    /// the strap's real `deviceId`. ANY NOOP-computed strap sibling (a "-noop"-suffixed id, not just the
    /// active strap's) reads "On-device" — matching by suffix so a computed row from a non-active strap
    /// can't fall through to `FusionSource.noopComputed`'s raw "NOOP" displayName; the imported strap source
    /// (`deviceId`, normally "my-whoop") reads "Whoop"; the Apple-Health source reads "Apple Health".
    /// Any other real source (Mi Band, Health Connect, nutrition) keeps its `FusionSource.displayName`
    ///, still the genuine merge winner, never a blanket claim. Mirror EXACTLY in Kotlin.
    static func provenanceDisplayLabel(rawSource: String, deviceId: String) -> String {
        if rawSource.hasPrefix(vo2MaxAttributionPrefix) {
            let raw = String(rawSource.dropFirst(vo2MaxAttributionPrefix.count))
            let method = vo2MaxEstimatorDisplayName(Vo2MaxEstimator(rawValue: raw))
            return "\(String(localized: "On-device")) · \(method)"
        }
        // #103/queue-11a follow-up: the Explorer's spo2 candidate-fallback rows (see
        // `spo2CandidateAttributionSource`) must read "strap estimate (unverified)", the SAME copy every
        // other candidate-fallback surface uses — never a device name, which would misrepresent an
        // unvalidated estimate as a calibrated reading in this table's Source column.
        if rawSource == spo2CandidateAttributionSource {
            return String(localized: "strap estimate (unverified)")
        }
        if rawSource.hasSuffix("-noop") { return String(localized: "On-device") }
        if rawSource == deviceId || rawSource == Repository.whoopSource { return Self.whoopBrandName }
        if rawSource == Repository.appleHealthSource { return "Apple Health" }
        // Localize the non-brand source names here rather than exposing the analytics layer's
        // intentionally locale-free wire/display vocabulary on Home.
        switch FusionSource(rawValue: rawSource) {
        case .healthConnect: return "Health Connect"
        case .xiaomiBand:    return "Mi Band"
        case .nutritionCsv:  return String(localized: "Nutrition")
        case .localCache:    return String(localized: "Cached")
        case .whoopImport:   return Self.whoopBrandName
        case .noopComputed:  return String(localized: "On-device")
        case .appleHealth:   return "Apple Health"
        case nil:            return rawSource
        }
    }

    /// PURE (unit-testable), whether a resolved raw source id is the Apple-Health/watch source. Kept
    /// separate from the cross-lane `provenanceDisplayLabel` so the Today-only "Apple Watch" relabel never
    /// leaks into the Kotlin-mirrored footer mapping.
    static func isWatchSource(_ rawSource: String?, appleHealthSource: String) -> Bool {
        rawSource == appleHealthSource
    }

    /// PURE (unit-testable), the Today chip label for a resolved source, relabelling the Apple-Health
    /// source as "Apple Watch" (the device the audience knows) and otherwise deferring to the shared
    /// provenance label so Whoop / on-device read identically to the footer.
    static func todayProvenanceChipLabel(rawSource: String, deviceId: String, appleHealthSource: String) -> String {
        if rawSource == appleHealthSource { return "Apple Watch" }
        return provenanceDisplayLabel(rawSource: rawSource, deviceId: deviceId)
    }

    /// Today hero wording names the provider that supplied the score inputs, not where NOOP ran the math.
    /// Registered device brands cover every live source; stable import ids cover providers without a paired
    /// registry row. Unknown ids remain visible rather than being falsely labelled as Whoop.
    static func todayScoreProviderLabel(sourceId: String, brand: String?) -> String {
        let source = sourceId.lowercased()
        switch source {
        case Repository.appleHealthSource: return "Apple Watch"
        case Repository.healthConnectSource: return "Health Connect"
        case "oura-import", "oura-api": return "Oura"
        case "fitbit-import": return "Fitbit"
        case "garmin-import": return "Garmin"
        case "xiaomi-band": return "Mi Band"
        case Repository.activityFileSource: return String(localized: "Workout files")
        default: break
        }

        if let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            return brand.caseInsensitiveCompare("WHOOP") == .orderedSame ? Self.whoopBrandName : brand
        }
        if source == Repository.whoopSource { return Self.whoopBrandName }
        switch FusionSource(rawValue: sourceId) {
        case .nutritionCsv: return String(localized: "Nutrition")
        case .localCache: return String(localized: "Cached")
        case let known?: return known.displayName
        case nil: return sourceId
        }
    }

    /// Parses a stored `yyyy-MM-dd` day key in the device-local zone (matching how DailyMetric.day
    /// is written), local so a key never shifts a day under timezone conversion.
    static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Falls
    /// back to the raw key if it can't be parsed so the caption is never empty.
    static func lastChargeDateFmt(_ dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    static var dayNavHints: [String] {
        [String(localized: "Swipe"), String(localized: "Tap")]
    }

    /// #829 follow-up: the named coordinate space the day-swipe drag and the HR-chart frame reader share,
    /// declared on the scaffold's content stack (the view the swipe gesture is attached to), so the mask's
    /// containment check compares like with like. Content-relative, so it is scroll-position independent.
    /// OUTSIDE the iOS conditional: the `.coordinateSpace` modifier and the chart's frame reader compile
    /// on macOS too (only iOS consults the mask), so the constant must exist on both platforms.
    static let daySwipeSpace = "todayDaySwipeSpace"

    /// Pure core of the HRV-vs-baseline delta: today's HRV against the mean of the prior nights' HRV,
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate), the insight then falls back to the state word.
    ///
    /// STOPGAP (#696): NOOP mixes HRV measurement methods on the shared `avgHrv` field,     /// strap/WHOOP-CSV HRV is RMSSD (~20-100 ms) while Apple-Health-imported HRV is SDNN
    /// (~100-200 ms). With no method awareness, an SDNN reading (e.g. an Oura ring's 176 ms)
    /// compared against an RMSSD baseline (~57 ms) yields a physiologically-impossible delta
    /// (+209%) and renders the alarming "210% over baseline" headline. Genuine night-to-night
    /// HRV variation essentially never exceeds ~±80-100%, so a magnitude beyond that is almost
    /// always a units/method artifact rather than a real swing. We suppress the misleading
    /// percentage comparison (return nil → callers fall back to the qualitative recovery-state
    /// word) when the delta is implausibly large. The raw HRV tile value stays honest; only the
    /// "X% over baseline" comparison is hidden. Proper fix = tag HRV provenance/method per row
    /// and isolate baselines (separate follow-up).
    static func hrvBaselineDeltaPct(today: Double, priorHrvs prior: [Double]) -> Int? {
        guard today > 0 else { return nil }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        let baseline = prior.reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        let pct = ((today - baseline) / baseline * 100).rounded()
        // Stopgap method-mismatch guard (#696): a real night-to-night HRV move never doubles or halves
        // the value, so a reading outside [0.5x, 2x] of the baseline is almost always a units/method
        // artifact (SDNN reads ~2-3x RMSSD) rather than a genuine swing. Drop the comparison in that case
        // so the alarming "X% over/under baseline" headline never renders (the insight falls back to the
        // qualitative recovery word). Gated on the RATIO, not abs(pct): the percentage is bounded at -100%
        // on the low side but unbounded high, so a symmetric abs() threshold can't catch a near-zero
        // reading. Proper fix tags HRV provenance/method per row and isolates baselines (follow-up).
        guard today <= 2.0 * baseline, today >= 0.5 * baseline else { return nil }
        return Int(pct)
    }

    /// The three score rings over a scenic hero background, WHOOP-style, with the Charge (recovery)
    /// ring centred and enlarged as the hero and smaller Rest / Effort rings flanking it. Each ring
    /// floats cleanly on the scenic field (no per-ring card); a tappable label + chevron sits beneath
    /// each and opens that score's section in the scoring guide. Rings are sized off the available
    /// width so the trio never crushes on a narrow phone nor bloats on iPad.
    /// #762: the hero ring diameter for a given row width. Clamped to [82, 98] so the trio never crushes on
    /// a narrow phone nor bloats on iPad; the linear middle term divides the usable width (less the two 22pt
    /// gaps and a small margin) across the three columns. Pure + static so the clamp can be unit-tested
    /// without a live view, and so the value feeding the SELF-SIZING row (no fixed 150pt clip) is the same
    /// one the test asserts. Mirror on Android if the hero ever moves to a measured-width sizing there.
    static func heroRingDiameter(rowWidth: CGFloat) -> CGFloat {
        min(98, max(82, (rowWidth - 56) / 3.4))
    }

    /// The localized natural-case display word for a score domain (Charge / Effort / Rest / Stress). The
    /// hero label uppercases this via `.textCase(.uppercase)`, so the catalog only needs the title-case key.
    /// `domain.rawValue` stays the stable styling/lookup id; this is purely the user-facing word. Mirror in
    /// Kotlin (the Android hero already reads its label from a localized resource, not the enum name).
    static func domainLabel(_ domain: DomainTheme) -> LocalizedStringKey {
        switch domain {
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .rest:   return "Rest"
        case .stress: return "Stress"
        }
    }

    /// The VoiceOver label for a hero ring's "how this score is calculated" button, with the domain word
    /// interpolated from a localized literal (so the spoken sentence is translated, not half-English).
    static func domainDetailAccessibilityLabel(_ domain: DomainTheme) -> LocalizedStringKey {
        switch domain {
        case .charge: return "Open your Charge detail"
        case .effort: return "Open your Effort detail"
        case .rest:   return "Open your Rest detail"
        case .stress: return "Open your Stress detail"
        }
    }

    /// The VoiceOver label for a hero ring's "how this score is calculated" chevron.
    static func domainGuideAccessibilityLabel(_ domain: DomainTheme) -> LocalizedStringKey {
        switch domain {
        case .charge: return "How Charge is calculated"
        case .effort: return "How Effort is calculated"
        case .rest:   return "How Rest is calculated"
        case .stress: return "How Stress is calculated"
        }
    }

    /// #829 - keep a Today HR zoom window valid as the loaded axis changes across reloads. Pure +
    /// unit-testable so the rule can't drift. nil zoom stays nil. When the day's START moves (a day step =
    /// a genuinely different day), the zoom is dropped (nil) so the new day opens at full scale. When only
    /// the END extended on the SAME day (today's window growing toward `now`), the existing zoom is kept but
    /// re-clamped into the grown bounds preserving its span, so a live refresh never yanks the user out of
    /// their zoom and the window can never sit outside the day. `oldAxis == nil` (first load) keeps the zoom
    /// re-clamped into the new bounds. Reuses `OverviewHRChart.panned(deltaSeconds: 0)` as the pure clamp.
    static func reclampHrZoom(_ zoom: ClosedRange<Date>?,
                              oldAxis: ClosedRange<Date>?,
                              newAxis: ClosedRange<Date>) -> ClosedRange<Date>? {
        guard let zoom else { return nil }
        // A moved start means we stepped to a different day, so open it un-zoomed.
        if let oldAxis, oldAxis.lowerBound != newAxis.lowerBound { return nil }
        // Same day (or first load): re-clamp the kept window into the current bounds, span preserved.
        return OverviewHRChart.panned(zoom, deltaSeconds: 0, bounds: newAxis)
    }

    /// Android's Today feed contract (`TodayScreen.recentCutoff`): sessions starting on or after the
    /// start of the day 13 days back — 14 days counting today. Named rather than inlined so the window
    /// is one thing on this platform too, and so the parity guard has something to point at.
    static func recentWorkoutsFeed(_ rows: [WorkoutRow], now: Date = Date()) -> [WorkoutRow] {
        let cal = Calendar.current
        guard let cutoff = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: now)) else { return rows }
        let cutoffTs = Int(cutoff.timeIntervalSince1970)
        return rows.filter { $0.startTs >= cutoffTs }
    }

    /// PURE: the "Synced from: …" summary string for the collapsed footer (S5). Names the sources with
    /// data using the audience-facing words ("WHOOP", "Apple Watch" for Apple Health, "Mi Band"); "No
    /// sources yet" when nothing is banked. Unit-testable so the collapsed copy can't drift. The expanded
    /// card still uses the existing per-source rows, so the Apple-Health provenance footer is unchanged.
    static func syncedFromSummary(hasWhoop: Bool, hasApple: Bool, hasXiaomi: Bool) -> String {
        var names: [String] = []
        if hasWhoop { names.append("WHOOP") }
        if hasApple { names.append("Apple Watch") }
        if hasXiaomi { names.append("Mi Band") }
        guard !names.isEmpty else { return String(localized: "No sources yet") }
        return String(localized: "Synced from: \(names.joined(separator: ", "))")
    }

    /// Pure gate used by the Steps tile and its state-matrix tests. `calibrationSampleDays` is accepted so
    /// the regression is explicit: partial fitter progress alone must never activate a strap-family feature.
    static func stepsPipelineActive(selectedModelRaw: String,
                                    hasDayData: Bool,
                                    calibrationCoefficient: Double,
                                    manualCoefficient: Double,
                                    calibrationSampleDays: Int) -> Bool {
        // Optional-chained deliberately: an unset (or unparseable) key is NOT a 4.0. The key only ever
        // holds a `WhoopModel` rawValue, so nil here means "no strap has been identified", not "4.0".
        let family = WhoopModel(rawValue: selectedModelRaw)?.deviceFamily
        // #1523 follow-up: a POSITIVELY identified 5/MG never sees this, whatever calibration state the
        // profile carries from an earlier strap. #1579 stopped a partial sample-day count activating the
        // affordance but left the coefficient paths able to, and those are profile-global — so a user who
        // calibrated a 4.0 and then moved to a 5.0 still got the 4.0 prompt on any day the 5.0 logged no
        // steps and no estimate existed. That is the same complaint #1523 opened, on a narrower trigger.
        //
        // The justification for the coefficient paths was preserving estimate behaviour across that
        // migration, but this gate does not control the estimate: `estSteps` comes from `stepsEstByDay`
        // and is computed independently. All this gate decides is whether a BLANK tile offers to
        // calibrate — and a strap that reports steps natively has nothing to calibrate.
        //
        // Android has been immune by construction all along: `stepsCalibrationPrompt` returns early on
        // `model != WhoopModel.WHOOP4.name` before reading any calibration state — and this is written the
        // same way round, "positively identified and NOT a 4.0", rather than "is a 5". Those are the same
        // set today because `WhoopModel` has exactly two cases, but they stop being the same the moment a
        // third is added, and the version that would then be wrong is the one naming a specific family.
        if let family, family != .whoop4 { return false }
        // The coefficient paths stay for everything else, and are NOT redundant with the family check: a
        // legacy 4.0 owner whose `selectedWhoopModel` was never written still has a coefficient, and
        // dropping these would silently take the gear away from them.
        return (family == .whoop4 && hasDayData)
            || calibrationCoefficient > 0
            || manualCoefficient > 0
    }

    /// #1816: the pure decision behind `stepsCalibrationCaption`, extracted so it can be unit-tested
    /// without a live view. Returns nil once a coefficient exists (a blank day is just a quiet one,
    /// not a missing input). Returns "No motion synced yet" when the strap has banked no motion —
    /// the motion half is the blocker, not the phone half, and the countdown that names only the
    /// phone half is a lie. Otherwise returns the engine's `needsMoreDays` headline. Twin of the
    /// Kotlin `stepsCalibrationPrompt` guard.
    static func stepsCalibrationCaption(coefficient: Double, manualCoefficient: Double,
                                        hasBankedMotion: Bool, sampleDays: Int) -> String? {
        guard coefficient <= 0, manualCoefficient <= 0 else { return nil }
        if !hasBankedMotion { return String(localized: "No motion synced yet") }
        let status = StepsEstimateEngine.CalibrationStatus.needsMoreDays(
            have: sampleDays,
            need: StepsEstimateEngine.minCalibrationDays)
        return status.headline
    }

    /// The reads that follow `selectedDayOffset`: the selected day's Rest score + provenance, its HR
    /// window + axis, the overlapping sleep band, today's in-progress Effort, and the one-shot auto-land.
    /// A handful of queries, so this ALWAYS runs on a refresh / day-switch / tab-return, the screen stays
    /// responsive even while the heavy history-wide set is deferred during a backfill (#755). The Rest tile
    /// sparkline (`sparks["sleep_performance"]`) is derived from the SAME `restSeries` read here so the
    /// tile's number and its mini-graph stay consistent and day-fresh. Byte-identical to the old inline
    /// values; only the read's location moved.
    ///
    /// #860 item 1: the launch "land on the most recent data day" (#605/#739) is RETIRED. A fresh launch now
    /// always shows today (offset 0, decided by `launchDayOffset` on the plain `@State selectedDayOffset`),
    /// so a calibrating user whose newest data is days back is no longer stranded on that old day after an
    /// app update. This pass therefore no longer mutates `selectedDayOffset`, so it has nothing to signal to
    /// the caller and returns void.
    ///
    /// #932: how long a TODAY snapshot may be served before a re-mount pays a genuine reload. Live banking
    /// does not bump `refreshSeq` (see the fast-path comment below), so this bounds the staleness of the
    /// restored HR curve / live Effort against the 1Hz stream. Rapid sidebar switching (the measured #932
    /// hitch) sits comfortably inside it, and even a genuine load runs up to ~30s behind live anyway (the
    /// Collector flush cadence), so two minutes of cache is the same order of freshness the screen had.
    static let todayCacheMaxAge: TimeInterval = 120

    /// The Component-2 "needs the strap" tile caption, the honest no-data state word a Charge/Rest tile
    /// shows instead of a bare blank when there's no value, no calibration count and nothing to carry.
    /// Matches `MetricTileState.needsStrap.title` verbatim so the tile and the explained note say the same
    /// words, both resolve from the SAME catalog key, so they stay in lockstep in every locale.
    static let needsStrapCaption = String(localized: "Needs the strap")

    /// H10, the honest empty-state caption for a recovery-vital tile (HRV / Resting HR / SpO₂ / Respiratory)
    /// when TODAY has no value yet and there's nothing to carry over. Those vitals are measured overnight, so
    /// "After tonight's sleep" tells the user WHEN the tile fills rather than leaving a bare ", " beside a lone
    /// unit that read as broken. Returns nil off-today (a past day keeps the plain unit, it's missing data the
    /// user can't act on now). Pure copy/gate so it can be unit-tested without a live view. Mirror in Kotlin.
    static func emptyVitalCaption(unit: String, isToday: Bool) -> String? {
        guard isToday else { return nil }
        return String(localized: "After tonight's sleep")
    }

    /// The Skin Temp card's value, extracted so the bimodal-column decision can be unit-tested without a
    /// live view. Nil (no reading anywhere in the carry chain) reads as an em-dash rather than a number.
    /// The Skin Temp card's value when the surface LEADS WITH THE ABSOLUTE (#1844) — the row supplies both
    /// numbers and `SkinTempDisplay.leadReading` picks, so a night that measured a real temperature shows
    /// one and only a night without falls back to the signed deviation. Nil (neither number anywhere in the
    /// carry chain) reads as an em-dash. The `Double?` sibling below stays for the deviation-only callers.
    static func skinTempCardValue(reading: SkinTempDisplay.Reading?, fahrenheit: Bool) -> String {
        guard let reading else { return "—" }
        return SkinTempDisplay.formatReading(reading, fahrenheit: fahrenheit)
    }

    /// Pure copy/gate behind `buildingHint`, extracted so it can be unit-tested without a live view.
    /// Rest fills in after a night's sleep; Effort fills in once cardio load is logged. Em-dash-free
    /// house style. Returns nil off-today and for any metric other than Effort/Rest (#527).
    static func buildingHintCopy(_ metric: KeyMetric, isToday: Bool) -> String? {
        guard isToday else { return nil }
        switch metric {
        case .rest:   return String(localized: "Building, wear it tonight")
        case .effort: return String(localized: "Building, moves as you do")
        default:      return nil
        }
    }

    /// Local wall-clock time for the HR trend's x-axis / tooltip, the chart spans one day, so it must
    /// show times, not the day-granularity default ("EEE d MMM"). Also formats the workout-tile caption's
    /// time range (#157). The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "7:10 AM"
    /// where 12-hour is preferred, "19:10" where 24-hour is, instead of forcing one on everyone.
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    static var hrTimeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    static func resolve(live: LiveState) -> SyncChipState {
        if live.backfilling {
            // The zero rule above. Negative cannot come off the wire (the decoder returns a ring delta),
            // but the bound reads the same either way. Android spells this `?.takeIf { it > 0 }`.
            return .syncing(chunks: live.syncChunksThisSession,
                            pagesBehind: live.pagesBehindAtConnect.flatMap { $0 > 0 ? $0 : nil })
        }
        if let ts = live.lastSyncedAt { return .synced(agoText: shortAgo(ts)) }
        if live.historySyncExperimental { return .experimentalLive }
        return .hidden
    }

    /// Compact relative age for the status card ("<1m" / "Nm" / "Nh" / "Nd") — deliberately terse.
    ///
    /// EVERY branch must read correctly with a trailing "ago", because that is the only way this value is
    /// ever consumed (`DevicesView` wraps it in "Synced %@ ago" and "Strap history synced %@ ago"). The
    /// sub-minute branch used to return the word "now", which produced the user-visible "Synced now ago"
    /// for the first minute after any sync (#1472). "<1m" composes; it also needs no catalog entry, being
    /// digits and symbols in every language.
    static func shortAgo(_ ts: TimeInterval) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970 - ts))
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }
}
