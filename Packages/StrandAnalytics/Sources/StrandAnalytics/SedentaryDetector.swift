import Foundation
import WhoopProtocol

// SedentaryDetector.swift — the pure core of the "inactivity reminder" (wrist buzz after sitting
// too long). Faithful port of the Android PR #419 logic (ActivityDetector.detectSedentaryBouts +
// InactivityPrefs.mayBuzzInactivity + WhoopBleClient.maybeBuzzInactivity de-dup), folded into one
// pure, deterministic, DB-free engine so Swift and Kotlin are a byte-identical pair.
//
// WHY GRAVITY, NOT STEPS: the WHOOP 4.0 exposes no step count over BLE — only the wrist
// accelerometer, and only via the ~15-min historical offload. Sedentary time is therefore inferred
// from gravity. The wrist moves constantly at a desk (typing, reaching), so "wrist stillness" is the
// wrong signal; what a "time to move" reminder needs is the ABSENCE OF AMBULATION (walking around).
// `detectSedentaryBouts` smooths the per-record gravity delta (reusing WorkoutDetector.activitySeries)
// over `smoothWindowS` and calls any stretch where that smoothed signal stays at/under `moveThresholdG`
// — i.e. no sustained walking — a sedentary bout. Typing and isolated reaches average out and keep the
// bout alive; sustained walking pushes the smoothed signal over the threshold and ends it. The defaults
// were calibrated from on-wrist data (desk ≈ 0.05–0.10 g smoothed, walking ≈ 0.2–0.4 g).
//
// PURITY: no I/O, no wall-clock reads. `nowSec` and `tzOffsetSec` (seconds east of UTC) are passed IN.
// Active-hours / quiet-hours are evaluated against the candidate bout's LOCAL END TIME, not `now`:
// gravity only reaches the app on the strap's offload flush, so an overnight bout is processed in the
// morning; a `now`-based check would wrongly admit it. Checking the bout's own end time is what makes
// "active hours excludes nighttime sleep" actually hold.
//
// All `ts`/`start`/`end`/`nowSec` are wall-clock unix SECONDS. Outputs are APPROXIMATE, not medical advice.

// MARK: - Output shapes

/// A sedentary ("haven't moved from my seat") period. Times are wall-clock unix seconds;
/// `durationS` mirrors `ExerciseSession.durationS`. APPROXIMATE.
public struct InactivityPeriod: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let durationS: Double
    public init(start: Int, end: Int, durationS: Double) {
        self.start = start; self.end = end; self.durationS = durationS
    }
}

/// The persisted de-dup / freshness state the reminder carries between offloads (restart-safe). The
/// caller stores this verbatim (it is the byte-identical analogue of the InactivityPrefs LAST_* keys)
/// and feeds the prior value back into the next `evaluate`. A fresh user starts from `.initial`.
public struct SedentaryState: Equatable, Sendable {
    /// Newest gravity ts already processed — a replayed / no-new-rows offload can't re-buzz.
    public var lastProcessedGravityTs: Int
    /// Unix-seconds of the last buzz (0 = never) — drives the re-nudge cadence.
    public var lastBuzzAt: Int
    /// Start of the last buzzed bout (0 = none) — distinguishes "same bout, re-nudge" from "new bout".
    public var lastBuzzedBoutStart: Int
    /// End of the last buzzed bout (0 = none).
    public var lastBuzzedBoutEnd: Int

    public init(lastProcessedGravityTs: Int = 0, lastBuzzAt: Int = 0,
                lastBuzzedBoutStart: Int = 0, lastBuzzedBoutEnd: Int = 0) {
        self.lastProcessedGravityTs = lastProcessedGravityTs
        self.lastBuzzAt = lastBuzzAt
        self.lastBuzzedBoutStart = lastBuzzedBoutStart
        self.lastBuzzedBoutEnd = lastBuzzedBoutEnd
    }

    /// A cold-start state (never processed, never buzzed).
    public static let initial = SedentaryState()
}

/// The decision the engine returns each offload: whether to buzz now, the next persisted state to
/// store, and (when buzzing) the buzz strength + the bout that triggered it (for logging / UI).
public struct SedentaryDecision: Equatable, Sendable {
    /// True if the wrist should buzz on this offload.
    public let shouldBuzz: Bool
    /// How many buzz loops to play (strength) when `shouldBuzz` — mirrors `config.buzzLoops`.
    public let buzzLoops: Int
    /// The current sedentary bout that drove the decision, or nil if none qualified.
    public let bout: InactivityPeriod?
    /// The state to persist for the next offload (always advance `lastProcessedGravityTs`).
    public let nextState: SedentaryState

    public init(shouldBuzz: Bool, buzzLoops: Int, bout: InactivityPeriod?, nextState: SedentaryState) {
        self.shouldBuzz = shouldBuzz; self.buzzLoops = buzzLoops
        self.bout = bout; self.nextState = nextState
    }
}

/// User-tunable config for the inactivity reminder. Mirrors InactivityPrefs (defaults included) plus
/// the global gates the Android guard reuses from NotifPrefs (master / quiet-hours / only-when-worn),
/// passed in here as plain values so the engine stays pure.
public struct SedentaryConfig: Equatable, Sendable {
    // ── Feature toggle + master gate ─────────────────────────────────────────
    /// Inactivity reminder feature toggle (InactivityPrefs.enabled, default OFF).
    public var enabled: Bool
    /// Global notification master switch (NotifPrefs.MASTER, default OFF). Buzz is inert if off.
    public var notificationsMasterOn: Bool

    // ── Detector tunables (ActivityDetector) ─────────────────────────────────
    /// Smoothed wrist-motion above this (g) counts as "walking around", ending a sedentary bout.
    public var moveThresholdG: Double
    /// Minimum sedentary-bout length (minutes) before the first nudge (InactivityPrefs threshold).
    public var thresholdMinutes: Int
    /// Rolling-mean window (seconds) for the movement signal.
    public var smoothWindowSeconds: Double

    // ── Cadence + strength ───────────────────────────────────────────────────
    /// If still seated, re-buzz this often (minutes). InactivityPrefs re-nudge, default 30.
    public var reNudgeMinutes: Int
    /// Buzz strength (loops). InactivityPrefs buzz loops, default 2.
    public var buzzLoops: Int

    // ── Active-hours window (InactivityPrefs) ────────────────────────────────
    /// Only nudge during the active-hours window (default ON).
    public var activeHoursEnabled: Bool
    /// Active-hours window start, local minute-of-day [0,1440) (default 9:00 = 540).
    public var activeStartMinutes: Int
    /// Active-hours window end, local minute-of-day [0,1440) (default 17:00 = 1020).
    public var activeEndMinutes: Int

    // ── Quiet-hours window (reused from NotifPrefs) ──────────────────────────
    /// Suppress during quiet hours (NotifPrefs.QUIET, default OFF).
    public var quietHoursEnabled: Bool
    /// Quiet-hours start, local minute-of-day (default 22:00 = 1320).
    public var quietStartMinutes: Int
    /// Quiet-hours end, local minute-of-day (default 7:00 = 420).
    public var quietEndMinutes: Int

    // ── Only-when-worn gate (reused from NotifPrefs) ─────────────────────────
    /// Require the strap to be worn (NotifPrefs.WORN, default ON).
    public var onlyWhenWorn: Bool

    public init(enabled: Bool = false,
                notificationsMasterOn: Bool = false,
                moveThresholdG: Double = SedentaryDetector.defaultMoveThresholdG,
                thresholdMinutes: Int = SedentaryDetector.defaultThresholdMinutes,
                smoothWindowSeconds: Double = SedentaryDetector.defaultSmoothWindowS,
                reNudgeMinutes: Int = SedentaryDetector.defaultReNudgeMinutes,
                buzzLoops: Int = SedentaryDetector.defaultBuzzLoops,
                activeHoursEnabled: Bool = true,
                activeStartMinutes: Int = SedentaryDetector.defaultActiveStartMin,
                activeEndMinutes: Int = SedentaryDetector.defaultActiveEndMin,
                quietHoursEnabled: Bool = false,
                quietStartMinutes: Int = SedentaryDetector.defaultQuietStartMin,
                quietEndMinutes: Int = SedentaryDetector.defaultQuietEndMin,
                onlyWhenWorn: Bool = true) {
        self.enabled = enabled
        self.notificationsMasterOn = notificationsMasterOn
        self.moveThresholdG = moveThresholdG
        self.thresholdMinutes = thresholdMinutes
        self.smoothWindowSeconds = smoothWindowSeconds
        self.reNudgeMinutes = reNudgeMinutes
        self.buzzLoops = buzzLoops
        self.activeHoursEnabled = activeHoursEnabled
        self.activeStartMinutes = activeStartMinutes
        self.activeEndMinutes = activeEndMinutes
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.onlyWhenWorn = onlyWhenWorn
    }
}

// MARK: - Engine

public enum SedentaryDetector {

    // MARK: Detector defaults (ActivityDetector parity)

    /// Smoothed wrist-motion above this (g) counts as "walking around", ending a sedentary bout.
    public static let defaultMoveThresholdG: Double = 0.15
    /// Rolling-mean window (seconds) for the movement signal — long enough that desk reaches / typing
    /// flurries average out, short enough that sustained walking still crosses the threshold within a
    /// minute or two.
    public static let defaultSmoothWindowS: Double = 240.0
    /// Break a sedentary bout when the inter-record time gap exceeds this (seconds). Also the freshness
    /// tolerance the live path uses to decide a bout is still "current".
    public static let maxGapS: Int = 20 * 60
    /// Default minimum sedentary-bout length (minutes) — InactivityPrefs threshold default.
    public static let defaultThresholdMinutes: Int = 45
    /// The detector's own floor when a caller doesn't pass a user threshold (ActivityDetector default).
    public static let defaultMinMinutes: Int = 15

    // MARK: Config defaults (InactivityPrefs / NotifPrefs parity)

    public static let defaultReNudgeMinutes: Int = 30
    public static let defaultBuzzLoops: Int = 2
    public static let defaultActiveStartMin: Int = 9 * 60   // 09:00
    public static let defaultActiveEndMin: Int = 17 * 60    // 17:00
    public static let defaultQuietStartMin: Int = 22 * 60   // 22:00
    public static let defaultQuietEndMin: Int = 7 * 60      // 07:00

    // MARK: - Detection (ActivityDetector.detectSedentaryBouts parity)

    /// Detect SEDENTARY bouts: stretches where the smoothed wrist-motion stays at/under `moveThresholdG`
    /// — the user hasn't walked around — for ≥ `minMinutes`. Typing and the occasional reach stay below
    /// the threshold and keep the bout alive; sustained walking ends it, as does a data gap > `maxGapS`.
    public static func detectSedentaryBouts(_ gravity: [GravitySample],
                                            moveThresholdG: Double = defaultMoveThresholdG,
                                            minMinutes: Int = defaultMinMinutes,
                                            smoothWindowSeconds: Double = defaultSmoothWindowS) -> [InactivityPeriod] {
        let rows = gravity.sorted { $0.ts < $1.ts }
        if rows.count < 2 { return [] }
        let motion = WorkoutDetector.activitySeries(rows)
        let smoothed = WorkoutDetector.smoothedIntensity(motion, windowS: smoothWindowSeconds)
        let ts = motion.map { $0.ts }
        let n = ts.count
        let minS = minMinutes * 60

        var out: [InactivityPeriod] = []
        var runStart = -1
        func closeRun(_ endIdx: Int) {
            if runStart >= 0 && runStart <= endIdx {
                let s = ts[runStart]
                let e = ts[endIdx]
                if e - s >= minS { out.append(InactivityPeriod(start: s, end: e, durationS: Double(e - s))) }
            }
            runStart = -1
        }
        for i in 0..<n {
            if i > 0 && ts[i] - ts[i - 1] > maxGapS { closeRun(i - 1) } // data gap ends the run
            if smoothed[i] > moveThresholdG {
                closeRun(i - 1) // walking-level motion ends the sedentary run
            } else if runStart < 0 {
                runStart = i
            }
        }
        closeRun(n - 1)
        return out
    }

    // MARK: - Pure time helpers (InactivityPrefs parity)

    /// Local minute-of-day [0,1440) for a unix-seconds instant given a tz offset (seconds east of UTC).
    public static func localMinuteOfDay(_ epochSec: Int, tzOffsetSec: Int) -> Int {
        let mod = ((epochSec + tzOffsetSec) % 86_400 + 86_400) % 86_400
        return mod / 60
    }

    /// Wrap-aware membership: is `minuteOfDay` inside `[startMin, endMin)` (window may cross midnight)?
    public static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// The global + active/quiet-hours gate, evaluated against the bout's LOCAL END TIME. True only when
    /// the inactivity reminder may buzz for a bout ending at `boutEndEpochSec`. Mirrors
    /// InactivityPrefs.mayBuzzInactivity (master / quiet hours / worn / active-hours-by-bout-end-time).
    public static func mayBuzz(_ config: SedentaryConfig, worn: Bool, boutEndEpochSec: Int, tzOffsetSec: Int) -> Bool {
        if !config.enabled { return false }
        if !config.notificationsMasterOn { return false }
        if config.quietHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if windowContains(mod, startMin: config.quietStartMinutes, endMin: config.quietEndMinutes) { return false }
        }
        if config.onlyWhenWorn && !worn { return false }
        if config.activeHoursEnabled {
            let mod = localMinuteOfDay(boutEndEpochSec, tzOffsetSec: tzOffsetSec)
            if !windowContains(mod, startMin: config.activeStartMinutes, endMin: config.activeEndMinutes) { return false }
        }
        return true
    }

    // MARK: - The decision (WhoopBleClient.maybeBuzzInactivity parity)

    /// Run the inactivity reminder over the freshly-arrived `gravity` window and decide whether to buzz.
    /// Pure: pass `nowSec` (the offload-completion instant) and `tzOffsetSec` IN; never read a clock.
    ///
    /// Mirrors the Android live path exactly:
    ///   1. Disabled → never buzz; state unchanged.
    ///   2. Only act when this offload advanced the newest gravity ts (replayed / no-new-rows → no-op);
    ///      when it did advance, persist the new `lastProcessedGravityTs`.
    ///   3. Pick the most-recent qualifying bout (≥ `thresholdMinutes`).
    ///   4. The bout must be CURRENT — its end within `maxGapS` of the newest sample (still seated).
    ///   5. Pass the global + active/quiet/worn gate (`mayBuzz`) on the bout's local end time.
    ///   6. Re-nudge a continuing bout on the user's cadence; alert a distinct new bout (one that starts
    ///      after the last buzzed bout's end, separated by movement) on its own crossing.
    public static func evaluate(_ gravity: [GravitySample],
                                state: SedentaryState,
                                config: SedentaryConfig,
                                worn: Bool,
                                nowSec: Int,
                                tzOffsetSec: Int) -> SedentaryDecision {
        func noBuzz(_ next: SedentaryState, _ bout: InactivityPeriod? = nil) -> SedentaryDecision {
            SedentaryDecision(shouldBuzz: false, buzzLoops: config.buzzLoops, bout: bout, nextState: next)
        }

        if !config.enabled { return noBuzz(state) }

        let newestGravityTs = gravity.map { $0.ts }.max()
        guard let newest = newestGravityTs else { return noBuzz(state) }

        // Only act when this offload brought new gravity (a replayed / no-new-rows sync can't fire).
        if newest <= state.lastProcessedGravityTs { return noBuzz(state) }
        var next = state
        next.lastProcessedGravityTs = newest

        let bouts = detectSedentaryBouts(gravity, moveThresholdG: config.moveThresholdG,
                                         minMinutes: config.thresholdMinutes,
                                         smoothWindowSeconds: config.smoothWindowSeconds)
        guard let bout = bouts.max(by: { $0.end < $1.end }) else { return noBuzz(next) }

        // The bout must be current — its end near the newest sample (the user is still seated).
        if newest - bout.end > maxGapS { return noBuzz(next, bout) }
        if !mayBuzz(config, worn: worn, boutEndEpochSec: bout.end, tzOffsetSec: tzOffsetSec) { return noBuzz(next, bout) }

        let reNudgeS = config.reNudgeMinutes * 60
        // Continues the last buzzed bout → re-nudge on cadence; a distinct new bout (which starts after
        // the last buzzed bout's end, separated by movement) alerts on its own crossing.
        let continues = bout.start <= state.lastBuzzedBoutEnd
        let shouldBuzz = state.lastBuzzAt == 0 || !continues || (nowSec - state.lastBuzzAt >= reNudgeS)
        if !shouldBuzz { return noBuzz(next, bout) }

        next.lastBuzzAt = nowSec
        next.lastBuzzedBoutStart = bout.start
        next.lastBuzzedBoutEnd = bout.end
        return SedentaryDecision(shouldBuzz: true, buzzLoops: config.buzzLoops, bout: bout, nextState: next)
    }
}
