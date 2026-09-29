import SwiftUI
import WhoopStore
import StrandDesign

// MARK: - Screen helpers lifted from upstream screens this fork replaced
//
// Each of these is declared at file scope inside an upstream screen (TodayView / SleepView /
// MetricExplorerView) that this fork keeps its own version of. Other upstream files — the Liquid
// Today, the sleep cards, the Devices screen — still reference them, so they are carried here
// verbatim rather than duplicated into this fork's screens.

/// Leaf-isolated so an in-progress workout's ~per-sample `AppModel` churn (the elapsed clock tick + the
/// rewritten `activeWorkout`) re-renders ONLY this card, never the whole Today dashboard, the same
/// leaf-isolation pattern the file documents for the live status/sync rows. Renders nothing when no workout
/// is active, so the card auto-appears/clears purely off `AppModel.activeWorkout`.
///
/// Non-private so the liquid Home (`LiquidTodayView`) renders the SAME leaf — the liquid rewrite dropped this
/// indicator (#105), and sharing one implementation keeps the two Today screens (and Android's
/// `WorkoutInProgressCard`) from drifting. It carries its own `app`/`router` environment objects, so a caller
/// only needs to place `ActiveWorkoutIndicatorSection()` in its body.
struct ActiveWorkoutIndicatorSection: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: NavRouter

    var body: some View {
        if let model = ActiveWorkoutIndicatorModel.make(from: app.activeWorkout) {
            ActiveWorkoutIndicatorCard(model: model) {
                StrandHaptic.selection.play()
                router.openActiveWorkout()
            }
            .transition(.opacity)
        }
    }
}

/// #245: the sync-status state used by the Devices screen's larger sync card, resolved once from
/// `LiveState`. THREE states mean the ABSENCE of active syncing reads as "caught up", not
/// "missing indicator" (the real #245 confusion): actively offloading → `⟳ N`; idle with a known
/// last-sync → `✓ Xm`; a 5/MG whose history sync is experimental (live-connected, no completed offload
/// yet) → `✓ live`. `.hidden` only on a true cold start (the building-scores note owns that case). Twin
/// of Android `SyncStatusChip`.
enum SyncChipState: Equatable {
    /// #689/#815 follow-up: `pagesBehind` is the strap's GET_DATA_RANGE ring backlog, sampled once at
    /// connect (`LiveState.pagesBehindAtConnect`) and never re-polled, so the copy reports it "at
    /// connect" rather than as a live figure. nil when no reply has landed this session, when the frame
    /// did not decode, AND when the backlog is zero: a chip that is actively syncing while claiming
    /// "0 pages behind" contradicts itself, and a zero sample carries nothing a reader can act on.
    /// `resolve` applies that rule so both platforms drop the same case. Twin of Android
    /// `SyncChipState.Syncing`.
    case syncing(chunks: Int, pagesBehind: Int?)
    case synced(agoText: String)
    case experimentalLive
    case hidden

    @MainActor
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
    private static func shortAgo(_ ts: TimeInterval) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970 - ts))
        if secs < 60 { return "<1m" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h" }
        return "\(hrs / 24)d"
    }
}

/// The "going to sleep / I'm awake" sleep-mark card (#461, Phase 1). Tapping logs a timestamped mark —
/// persisted to the `sleep_mark` metric series AND appended to the shareable strap log — then confirms
/// with a haptic and a transient line. LOGGING ONLY: a mark never touches the sleep detector or the
/// night boundaries. Owns `live` (it appends to the strap log) + `repo` (the metric-series write) and
/// the `lastMark` confirmation state, so its strap-log write keeps working without SleepView observing.
/// The "Sleep marks" tap-to-log card. Lives in the Sleep tab but is also hostable in Today
/// (#today-hosted-cards), so it is `internal` (not `private`) and self-contained — it reads only the
/// shared `repo`/`live` environment objects, both present on Today too.
struct SleepMarkCard: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var live: LiveState

    /// The most recent sleep-mark the user tapped, shown as a transient confirmation line under the
    /// two buttons. Drives the SwiftUI haptic landing too. LOGGING-ONLY: a mark never feeds the sleep
    /// detector — it's persisted to the metric series + strap log. (#461)
    @State private var lastMark: SleepMark?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep marks", overline: "Tap to log")
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Tap when you're heading to bed or when you wake. Each tap is logged with the time. It doesn't change tonight's detected sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: NoopMetrics.gap) {
                        // Routed through the unified NoopButton system so the two marks sit identically
                        // (sentence-case label, leading icon at 8pt, controlHeight=48, no glow).
                        NoopButton("Going to sleep", systemImage: "moon.zzz.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.bedtime) }
                            .accessibilityLabel("Log going to sleep")

                        NoopButton("I'm awake", systemImage: "sun.max.fill",
                                   kind: .secondary, fullWidth: true) { logMark(.wake) }
                            .accessibilityLabel("Log waking up")
                    }
                    if let lastMark {
                        Text(lastMark.confirmation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.restColor)
                            .transition(.opacity)
                            .accessibilityLabel(lastMark.confirmation)
                    }
                }
            }
        }
        // A success haptic lands when a new mark is captured (value-driven, not per-tap), matching the
        // app's sparse tactile vocabulary. No-op on macOS.
        .strandHaptic(.success, trigger: lastMark?.tsMs ?? 0)
    }

    /// Persist + log a tapped mark. Optimistically shows the confirmation immediately, fires the
    /// haptic via `lastMark`, appends the human-readable strap-log line, then writes the metric-series
    /// row through the repo's live store handle (no new Repository API, no schema change). The write is
    /// idempotent by (deviceId, day, key). (#461)
    private func logMark(_ type: SleepMarkType) {
        let mark = SleepMark(type: type)
        withAnimation(.easeOut(duration: 0.2)) { lastMark = mark }
        // The shareable strap log is the human-readable surface that lands in a debug export.
        live.append(log: mark.logLine)
        Task {
            guard let store = await repo.storeHandle() else { return }
            try? await store.upsertMetricSeries([mark.metricPoint], deviceId: repo.deviceId)
        }
    }
}

func vo2MaxEstimatorDisplayName(_ estimator: Vo2MaxEstimator?) -> String {
    switch estimator {
    case .nes: return "Nes 2011"
    case .uth: return "Uth 2004"
    case nil:  return String(localized: "Unknown")
    }
}

private struct ActiveWorkoutIndicatorCard: View {
    let model: ActiveWorkoutIndicatorModel
    let onReturn: () -> Void

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    // Decorative "live" dot, hidden from VoiceOver (the card itself reads the full state).
                    Circle()
                        .fill(StrandPalette.metricRose)
                        .frame(width: NoopMetrics.space2, height: NoopMetrics.space2)
                        .accessibilityHidden(true)
                    Text("WORKOUT IN PROGRESS")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.metricRose)
                    // A frozen clock alone is ambiguous with a STALLED one, so say which it is. Reuses the
                    // "Paused" string #1533 already localized rather than minting new copy for a tag.
                    if model.isPaused {
                        Text("Paused")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    // A per-second live clock. The TimelineView re-evaluates ONLY this Text every second, so
                    // the tick never re-renders the rest of the card (let alone TodayView.body). bodyNumber
                    // already carries `.monospacedDigit()`, so no extra modifier here.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ActiveWorkoutIndicatorModel.elapsed(
                            since: model.startedAt, pausedAt: model.pausedAt,
                            pausedDuration: model.pausedDuration, now: context.date))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: NoopMetrics.cardInnerSpacing) {
                        sportLabel
                        Spacer(minLength: NoopMetrics.space2)
                        NoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, action: onReturn)
                    }

                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        sportLabel
                        NoopButton("Return to workout", systemImage: "arrow.forward.circle.fill",
                                   kind: .primary, fullWidth: true, action: onReturn)
                    }
                }
            }
        }
        // Combine the card into one VoiceOver element so the dot + label + clock + button read as a single
        // "Workout in progress" actionable item rather than five separate stops.
        .accessibilityElement(children: .combine)
    }

    private var sportLabel: some View {
        Text(model.sport)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The Today indicator's value-typed view model: just the sport label + the workout's start, derived from
/// `AppModel.ActiveWorkout`. Equatable so the leaf below only re-renders when one of these actually changes,
/// and the elapsed clock is formatted from a pure function the tests pin.
struct ActiveWorkoutIndicatorModel: Equatable {
    let sport: String
    let startedAt: Date
    /// The pause state has to be CARRIED, not just consulted: this value type is what the card renders
    /// from, so without these two fields the indicator cannot subtract the paused time or say it is
    /// paused, however correct `AppModel` is. That is precisely how it kept counting through #1533.
    var pausedAt: Date? = nil
    var pausedDuration: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

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
}

/// COMPONENT 2, the explained state of one score/tile on Today. `scored` carries the real value;
/// the other three NEVER carry a number (the honesty rule, calibrating / needsStrap show no value,
/// carried always stamped with its date). Each non-scored case yields a title, a detail line, and a
/// next step the UI renders instead of a bare blank.
enum MetricTileState: Equatable {
    /// Today's own value exists, the caller renders the number itself; this case is the "all good" gate.
    case scored
    /// Baselines still cold-start: `nightsRemaining` more nights until the score is personal. No number.
    case calibrating(nightsRemaining: Int)
    /// A prior scored day shown pre-tonight (#543 carry-over). `date` is that scored day's own date.
    /// `stale` is true when that day is older than the freshness cap (#779): the carry is still shown so the
    /// recovery side isn't a bare blank, but it's relabelled "Latest sleep" so a weeks-old import is never
    /// passed off as "Last night".
    case carriedLastNight(date: String, stale: Bool)
    /// No data for the period, strap not worn / not connected / not synced. No number.
    case needsStrap

    /// The state's short title. `scored` has no title (the value is the headline) so it returns nil.
    /// Verbatim spec copy; `\(...)` interpolation feeds the dynamic value into the LocalizedStringKey slot.
    var title: LocalizedStringKey? {
        switch self {
        case .scored:                       return nil
        case .calibrating:                  return "Calibrating"
        case .carriedLastNight(let date, let stale):
            // A LocalizedStringKey literal so the extractor catalogues the "Latest sleep · %@" /
            // "Last night · %@" format keys; the rendered English string is unchanged.
            return stale ? "Latest sleep · \(date)" : "Last night · \(date)"
        case .needsStrap:                   return "Needs the strap"
        }
    }

    /// The one-line detail + next step. Verbatim spec copy.
    var detail: LocalizedStringKey? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // Whole-phrase singular/plural variants, never a stitched "night(s)" fragment, so each
            // reads as one clean catalog key and still pluralises honestly.
            return n == 1
                ? "Building your baseline. About 1 more night until your scores are personal."
                : "Building your baseline. About \(n) more nights until your scores are personal."
        case .carriedLastNight(_, let stale):
            // A fresh post-rollover carry tells you tonight's score is on its way; a stale carry (an older
            // import, #779) instead explains the number is from that earlier session, not today.
            return stale
                ? "This is your last scored session. Wear the strap overnight for a fresh score."
                : "Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// VoiceOver-friendly plain string of title + detail (no markdown interpolation surprises). nil when scored.
    var accessibilityText: String? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // Whole-string singular/plural variants, one key each, never a stitched tail fragment.
            return n == 1
                ? String(localized: "Calibrating. Building your baseline. About 1 more night until your scores are personal.")
                : String(localized: "Calibrating. Building your baseline. About \(n) more nights until your scores are personal.")
        case .carriedLastNight(let date, let stale):
            return stale
                ? String(localized: "Latest sleep, \(date). This is your last scored session. Wear the strap overnight for a fresh score.")
                : String(localized: "Last night, \(date). Tonight's lands after you sleep with the strap on.")
        case .needsStrap:
            return String(localized: "Needs the strap. No data for today. Was your strap worn and connected overnight?")
        }
    }

    /// Convenience for the hero, where calibration is already richly explained by the data-confidence
    /// pill + Synthesis card + ring overlay, so the explained note defers to those for that one case.
    var isCalibrating: Bool {
        if case .calibrating = self { return true }
        return false
    }

    /// PURE mapper (unit-testable), the honest precedence behind every Today score/tile state, given
    /// the engine outputs already computed on the view. Mirror EXACTLY in Kotlin (same order of checks):
    ///   1. today's own value exists            → `.scored`
    ///   2. still mid-calibration (today only)  → `.calibrating(nightsRemaining)`
    ///   3. a prior scored day to carry (#543)  → `.carriedLastNight(date, stale)`
    ///   4. nothing banked anywhere             → `.needsStrap`
    /// `nightsRemaining` is clamped to AT LEAST 1 so a boundary count never reads "0 more nights" while
    /// calibration is genuinely still on (the singular/plural rule then reads the clamped value). Mirror
    /// the Kotlin `coerceAtLeast(1)` exactly. `carriedStale` (#779) relabels an out-of-cap carry to
    /// "Latest sleep" so a weeks-old import is never passed off as "Last night".
    static func resolve(hasTodayValue: Bool,
                        calibratingNightsRemaining: Int?,
                        carriedDate: String?,
                        carriedStale: Bool = false) -> MetricTileState {
        if hasTodayValue { return .scored }
        if let remaining = calibratingNightsRemaining { return .calibrating(nightsRemaining: max(1, remaining)) }
        if let date = carriedDate { return .carriedLastNight(date: date, stale: carriedStale) }
        return .needsStrap
    }
}

/// COMPONENT 3, the strap's live recording status, mapped honestly from the BLE connection + last-sync.
/// One clear chip on Today so people know it's working, or know it isn't and why. Mirrors the Kotlin
/// Today lane 1:1 (same cases, same order, same words).
enum RecordingState: Equatable {
    /// Connected and saving data live.
    case recording
    /// Not connected now but synced `minutesAgo` minutes back, reconnect to pull the latest.
    case lastSynced(minutesAgo: Int)
    /// Strap not connected and nothing fresh to fall back on.
    case notRecording
    /// #580, a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
    /// offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
    /// experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the mapper.
    case historyExperimental
    /// #612, connected with no live HR AND no evidence data is actually flowing — either this is the
    /// strap's first-ever pairing (never once synced) or a WHOOP-4/generic strap whose last several
    /// offloads all came back empty (`LiveState.sustainedEmptyOffload`). Distinct from `.notRecording`:
    /// the link genuinely IS up, so claiming "Strap not connected" would be false.
    case connectedNoData

    /// The chip's short label. Verbatim spec copy; the dynamic "Xm" goes into the LocalizedStringKey slot.
    var label: LocalizedStringKey {
        switch self {
        case .recording:                 return "Recording"
        case .lastSynced(let mins):      return "Last synced \(mins)m ago"
        case .notRecording:              return "Not recording"
        case .historyExperimental:       return "Connected"
        case .connectedNoData:           return "Connected"
        }
    }

    /// The supporting detail line. Verbatim spec copy.
    var detail: LocalizedStringKey {
        switch self {
        case .recording:           return "Your strap is connected and saving data."
        case .lastSynced:          return "Reconnect to pull the latest."
        case .notRecording:        return "Strap not connected. Tap to connect."
        case .historyExperimental: return "History sync is experimental on 5.0."
        case .connectedNoData:     return "No live heart rate or synced history yet this session."
        }
    }

    /// VoiceOver plain string (label + detail).
    var accessibilityText: String {
        switch self {
        case .recording:
            return String(localized: "Recording. Your strap is connected and saving data.")
        case .lastSynced(let mins):
            return String(localized: "Last synced \(mins) minutes ago. Reconnect to pull the latest.")
        case .notRecording:
            return String(localized: "Not recording. Strap not connected. Tap to connect.")
        case .historyExperimental:
            return String(localized: "Connected. History sync is experimental on 5.0.")
        case .connectedNoData:
            return String(localized: "Connected. No live heart rate or synced history yet this session.")
        }
    }

    /// PURE mapper (unit-testable), `recording` IFF (connected AND a live heart-rate sample is currently
    /// present). A connection with no live HR yet (handshaking, no PPG, strap off the wrist) is honestly
    /// NOT recording — but a genuinely connected strap that has never once synced, or one whose recent
    /// offloads are a SUSTAINED streak of empty (`sustainedEmptyOffload`, #612), still IS connected, so
    /// it reads `.connectedNoData` rather than the false "Strap not connected". Otherwise, if a last-sync
    /// time is known, reads "Last synced Xm ago"; else "Not recording". `lastSyncedAt` / `now` are unix
    /// seconds; the minute count clamps at >= 0 (strap-clock skew can't read negative) and uses ceil so a
    /// 30-second-old sync reads "1m ago" rather than "0m ago". Mirror EXACTLY in Kotlin.
    static func resolve(connected: Bool,
                        heartRate: Int?,
                        lastSyncedAt: TimeInterval?,
                        sustainedEmptyOffload: Bool = false,
                        now: TimeInterval = Date().timeIntervalSince1970) -> RecordingState {
        if connected && heartRate != nil { return .recording }
        if connected && heartRate == nil && (lastSyncedAt == nil || sustainedEmptyOffload) {
            return .connectedNoData
        }
        if let at = lastSyncedAt {
            let secs = max(0, now - at)
            let mins = Int((secs / 60).rounded(.up))
            return .lastSynced(minutesAgo: mins)
        }
        return .notRecording
    }
}

/// The compact 36pt recording-status light in the iOS top bar, a colour-coded dot (green recording,
/// amber last-synced, red not recording, accent for experimental 5.0 history). Taps to Devices. Owns
/// the `LiveState` observation so a live-HR tick refreshes only this dot.
private struct RecordingStatusLight: View {
    @EnvironmentObject private var live: LiveState
    let selectedDayOffset: Int
    let onTap: () -> Void

    /// Drives the syncing pulse; toggled in `.task` while an offload runs (never during body eval).
    @State private var pulsing = false

    /// This `repeatForever` ring had NO motion gate of any kind — it pulsed under system Reduce
    /// Motion too, which was already a bug (the Android twin's ConnectionDot had the same one, fixed
    /// in #911). It also ran precisely while the strap was offloading history, i.e. while the app was
    /// already busy. Gated on all three quiet signals now.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    /// Colour for the light: green recording, amber last-synced, red not recording, accent for
    /// experimental history. Mirrors the prior `TodayView.recordingHue` semantics verbatim.
    private func hue(_ state: RecordingState) -> Color {
        switch state {
        case .recording:           return StrandPalette.statusPositive
        case .lastSynced:          return StrandPalette.statusWarning
        case .notRecording:        return Color(red: 0.98, green: 0.27, blue: 0.23)
        case .historyExperimental: return StrandPalette.accent
        case .connectedNoData:     return StrandPalette.accent
        }
    }

    var body: some View {
        // The 36pt chip ALWAYS renders so the top-bar icon row never jumps when you scrub to a past day.
        // A live recording state colours the dot (green / amber / red); a past day (no state) shows a muted
        // dot and the chip is non-actionable, recording status only means something for today.
        let state = TodayView.recordingState(live: live, selectedDayOffset: selectedDayOffset)
        // #245: while the strap is actively offloading history, surface a visible SYNC indicator right in
        // the header (users otherwise only saw progress under More → Live). This reads `live.backfilling`
        // directly rather than adding a `RecordingState` case, so the pure mapper + its Kotlin twin stay
        // untouched — a UI-only accent pulse, gated to today (a past day never syncs). The dot keeps its
        // recording hue underneath; an expanding accent ring says "handing over history now".
        let syncing = live.backfilling && selectedDayOffset == 0
        Button(action: onTap) {
            Circle().fill(StrandPalette.surfaceInset)
                .frame(width: 36, height: 36)
                .overlay {
                    if syncing {
                        // Expanding, fading accent ring behind a steady accent dot — a "pulling data" beat.
                        Circle()
                            .stroke(StrandPalette.accent, lineWidth: 2)
                            .frame(width: 10, height: 10)
                            .scaleEffect(pulsing ? 2.6 : 1.0)
                            .opacity(pulsing ? 0.0 : 0.9)
                        Circle().fill(StrandPalette.accent).frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .fill(state.map(hue) ?? StrandPalette.textTertiary.opacity(0.4))
                            .frame(width: 10, height: 10)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == nil && !syncing)
        .accessibilityLabel(syncing ? syncingAccessibilityLabel
            : (state?.accessibilityText ?? String(localized: "Recording status, not shown for a past day")))
        // Run the repeating pulse only while syncing AND nothing is asking for quiet motion; the
        // `.task(id:)` auto-cancels when the flag flips, so there is no timer left running once the
        // offload ends (or Today goes away). Without the pulse the steady accent dot still says
        // "syncing" — the information survives, only the loop stops.
        .task(id: syncing) {
            guard syncing, !motion.poseStill(reduceMotion) else { pulsing = false; return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }

    /// VoiceOver read-out while offloading: names the running chunk count so it matches the Live badge.
    private var syncingAccessibilityLabel: String {
        let n = live.syncChunksThisSession
        return n > 0
            ? String(localized: "Syncing strap history, chunk \(n)")
            : String(localized: "Syncing strap history")
    }
}

/// #103/queue-11a follow-up: a display-source token for a `spo2` reading that came from the
/// `spo2_candidate` fallback (WHOOP `spo2_candidate_82` or Oura ceiling@100 `0x6F`, device-conditional)
/// rather than a calibrated `spo2Pct` import. Every OTHER surface that shows this fallback (Today's Key
/// Metrics tile, `VitalSignsSummary`, `LiquidTodayView`) already labels it "strap estimate (unverified)"
/// — this Explorer/"Your Cards" drill-down had no candidate fallback at all until now (found 2026-08-24:
/// an Oura-only or WHOOP-4.0-only install with the toggle ON saw nothing here past the last calibrated
/// import, even though the Key Metrics tile right next to it showed a real number). Same
/// prefix-token idiom as `vo2MaxAttributionSource` just below, so the existing readings-table plumbing
/// needs no new machinery — only `TodayView.provenanceDisplayLabel` gains one more case.
let spo2CandidateAttributionSource = "spo2-candidate-estimate"

let vo2MaxAttributionPrefix = "vo2max-estimator:"

/// A display-source token that keeps the existing readings-table plumbing while naming the estimator.
/// `nil` is deliberately preserved as `unknown`; a legacy point must never inherit today's profile method.
func vo2MaxAttributionSource(_ estimator: Vo2MaxEstimator?) -> String {
    vo2MaxAttributionPrefix + (estimator?.rawValue ?? "unknown")
}
