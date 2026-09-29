import Foundation

// ActivityCostEngine.swift — "what each activity costs your recovery".
//
// Pure, deterministic, DB-free. Given which days you tagged each SPORT on and your
// daily Charge (recovery, 0–100) history, this answers, per sport: how far does your
// next-morning Charge sit BELOW your rest-day baseline after a session, and how many
// days does it take to bounce back?
//
// This is a descriptive AVERAGE, not a measurement of any single session — it leans
// on the levers that are actually in the data (the day a session was tagged, and the
// Charge values on the days after) and stays explainable line by line. Nothing here
// is learned; it is plain means over aligned day keys.
//
// Per sport S:
//
//   restDays      = days with a Charge value that are neither tagged with ANY sport NOR inside a
//                   session's forward recovery window (D+1…D+maxLookahead) — your UNTOUCHED days.
//   baselineMean  = mean Charge over restDays. This is your "untouched" recovery — the
//                   bar each sport is measured against. (Shared across all sports.)
//
//   For each tagged day D of sport S that HAS a Charge value on D+1:
//     nextMorning(D) = Charge[D+1]
//   meanNextMorning = mean of those nextMorning(D).
//   n               = how many tagged days contributed a D+1 value.
//
//   delta ("cost")  = baselineMean − meanNextMorning.
//                     POSITIVE → the morning after this sport your Charge sits BELOW
//                     your rest baseline (it cost you); negative → you wake higher.
//
//   daysToBaseline  = how long recovery takes to climb back. Build an AVERAGED forward
//                     trajectory traj[k] = mean over tagged days D (that have a Charge
//                     on D+k) of Charge[D+k], for k = 1…maxLookahead. daysToBaseline is
//                     the smallest k whose traj[k] ≥ baselineMean − tol (tol = 3 pts).
//                     nil if it never gets within tol inside the window, or n is too thin.
//
// Confidence (reuses ScoreConfidence): a sport with fewer than minSessions tagged
// next-morning pairs is OMITTED entirely (too thin to say anything honest);
// minSessions…<solidSessions → .building; ≥ solidSessions → .solid.
//
// Ranking: biggest |delta| first (the sports that move you most), .solid ahead of
// .building on a tie, then sport name ascending — a fully deterministic, stable order.
//
// All day arithmetic goes through CorrelationEngine.shiftDay (fixed UTC calendar) and
// all the means are self-contained so the Kotlin mirror is line-for-line.

// MARK: - Result

/// One sport's recovery cost: how far below your rest baseline your next-morning Charge
/// sits after a session of this sport, and how long it takes to bounce back.
public struct ActivityCost: Equatable, Sendable {
    /// The sport key (raw WHOOP sport / activity name, as tagged on the day).
    public let sport: String
    /// Signed cost in Charge points: baselineMean − meanNextMorning. Positive = the
    /// morning after sits BELOW your rest baseline (it cost you recovery).
    public let delta: Double
    /// Mean next-morning (D+1) Charge over tagged days that had a D+1 value, 0–100.
    public let meanNextMorning: Double
    /// Mean rest-day Charge this sport is measured against (shared across sports), 0–100.
    public let baselineMean: Double
    /// Days for the averaged forward trajectory to climb back within `tolerance` of the
    /// baseline; nil when it never recovers inside the lookahead window (or too thin).
    public let daysToBaseline: Int?
    /// Number of tagged days that contributed a D+1 Charge value.
    public let n: Int
    /// Per-result certainty tier (reuses the Charge/Effort/Rest confidence ladder).
    public let confidence: ScoreConfidence

    public init(sport: String, delta: Double, meanNextMorning: Double, baselineMean: Double,
                daysToBaseline: Int?, n: Int, confidence: ScoreConfidence) {
        self.sport = sport
        self.delta = delta
        self.meanNextMorning = meanNextMorning
        self.baselineMean = baselineMean
        self.daysToBaseline = daysToBaseline
        self.n = n
        self.confidence = confidence
    }

    /// Plain-English summary of this sport's recovery cost. Degrades gracefully: drops
    /// the bounce-back clause when `daysToBaseline` is nil, and says "barely move" when
    /// the cost is under a point in either direction.
    public func sentence() -> String {
        let mag = abs(delta)
        let points = ActivityCostEngine.roundToInt(mag)
        if mag < ActivityCostEngine.barelyMovesPoints {
            return "Sessions like this barely move your next-day Charge (n=\(n))."
        }
        let direction = delta >= 0 ? "cost you" : "lift"
        let head = "Sessions like this usually \(direction) about \(points) Charge "
            + "point\(points == 1 ? "" : "s") the next morning"
        if let days = daysToBaseline {
            return head + " and take about \(days) day\(days == 1 ? "" : "s") to bounce back (n=\(n))."
        }
        return head + " (n=\(n))."
    }
}

// MARK: - Engine

public enum ActivityCostEngine {

    // MARK: Tunables (documented, deterministic — NOT learned)

    /// Tagged next-morning pairs below which a sport is OMITTED (too thin to report).
    public static let minSessions: Int = 4
    /// Pairs at/above which a sport's confidence is `.solid` (else `.building`).
    public static let solidSessions: Int = 8
    /// How many days forward the bounce-back trajectory is probed (D+1 … D+maxLookahead).
    public static let maxLookahead: Int = 7
    /// Charge points within the baseline that count as "recovered" for daysToBaseline.
    public static let tolerance: Double = 3.0
    /// |delta| under this (points) reads as "barely moves" in `sentence()`.
    public static let barelyMovesPoints: Double = 1.0

    // MARK: - Evaluate

    /// Compute each sport's recovery cost from tagged activity days and daily Charge.
    ///
    /// - Parameters:
    ///   - activityDaysBySport: per sport, the SET of "yyyy-MM-dd" day keys that sport
    ///     was tagged on. Using a Set means same-day duplicates are already collapsed.
    ///   - recoveryByDay: daily Charge (recovery, 0–100) keyed by "yyyy-MM-dd".
    /// - Returns: one `ActivityCost` per sport that cleared `minSessions`, ranked by
    ///   |delta| desc, `.solid` before `.building`, sport name ascending on a tie.
    ///   Empty input (or no sport thick enough) → an empty array.
    public static func evaluate(activityDaysBySport: [String: Set<String>],
                                recoveryByDay: [String: Double]) -> [ActivityCost] {
        guard !activityDaysBySport.isEmpty, !recoveryByDay.isEmpty else { return [] }

        // Rest days = days WITH a Charge value that are neither tagged with ANY sport NOR sit inside
        // the forward recovery window (D+1 … D+maxLookahead) of any tagged day. Excluding the
        // after-effect window matters: the mornings *after* a session are exactly the days the cost
        // suppresses, so counting them as "rest" would contaminate the baseline with the very thing
        // we're measuring (understating every cost). The baseline must be your genuinely UNTOUCHED days.
        var activeUnion: Set<String> = []
        for (_, days) in activityDaysBySport { activeUnion.formUnion(days) }
        var affected = activeUnion
        for day in activeUnion {
            for k in 1...maxLookahead {
                if let d = CorrelationEngine.shiftDay(day, by: k) { affected.insert(d) }
            }
        }
        var restValues: [Double] = []
        for (day, value) in recoveryByDay where !affected.contains(day) {
            restValues.append(value)
        }
        // No untouched days → no baseline to measure against → nothing honest to say.
        guard !restValues.isEmpty else { return [] }
        let baselineMean = mean(restValues)

        var results: [ActivityCost] = []
        // Sort sports up front so the build order (and any downstream tie behaviour) is
        // deterministic regardless of dictionary iteration order.
        for sport in activityDaysBySport.keys.sorted() {
            let taggedDays = activityDaysBySport[sport]!

            // Collect next-morning (D+1) Charge for each tagged day that has one.
            var nextMornings: [Double] = []
            for day in taggedDays {
                guard let d1 = CorrelationEngine.shiftDay(day, by: 1),
                      let v = recoveryByDay[d1] else { continue }
                nextMornings.append(v)
            }
            let n = nextMornings.count
            // Thin sports are omitted entirely — better silent than fabricated.
            if n < minSessions { continue }

            let meanNextMorning = mean(nextMornings)
            let delta = baselineMean - meanNextMorning
            let daysToBaseline = forwardDaysToBaseline(taggedDays: taggedDays,
                                                       recoveryByDay: recoveryByDay,
                                                       baselineMean: baselineMean)
            let confidence: ScoreConfidence = n >= solidSessions ? .solid : .building

            results.append(ActivityCost(sport: sport, delta: delta,
                                        meanNextMorning: meanNextMorning,
                                        baselineMean: baselineMean,
                                        daysToBaseline: daysToBaseline,
                                        n: n, confidence: confidence))
        }

        return rank(results)
    }

    // MARK: - Bounce-back trajectory

    /// Smallest k in 1…maxLookahead where the AVERAGED forward Charge trajectory
    /// traj[k] = mean over tagged days D (with a Charge on D+k) of Charge[D+k] climbs to
    /// within `tolerance` of `baselineMean`. nil if it never does inside the window or no
    /// day contributed a value at that horizon.
    static func forwardDaysToBaseline(taggedDays: Set<String>,
                                      recoveryByDay: [String: Double],
                                      baselineMean: Double) -> Int? {
        let target = baselineMean - tolerance
        for k in 1...maxLookahead {
            var vals: [Double] = []
            for day in taggedDays {
                guard let dk = CorrelationEngine.shiftDay(day, by: k),
                      let v = recoveryByDay[dk] else { continue }
                vals.append(v)
            }
            guard !vals.isEmpty else { continue }
            if mean(vals) >= target { return k }
        }
        return nil
    }

    // MARK: - Ranking

    /// Stable rank: |delta| desc, then .solid before .building, then sport name asc.
    static func rank(_ items: [ActivityCost]) -> [ActivityCost] {
        items.sorted { a, b in
            let da = abs(a.delta), db = abs(b.delta)
            if da != db { return da > db }
            let ra = confidenceRank(a.confidence), rb = confidenceRank(b.confidence)
            if ra != rb { return ra > rb }   // higher rank (solid) first
            return a.sport < b.sport
        }
    }

    /// Ordinal so .solid sorts ahead of .building (and .calibrating last).
    static func confidenceRank(_ c: ScoreConfidence) -> Int {
        switch c {
        case .solid: return 2
        case .building: return 1
        case .calibrating: return 0
        }
    }

    // MARK: - Stats (self-contained so the Kotlin mirror is line-for-line)

    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Round half away from zero to an Int — matches Kotlin's roundToInt for the
    /// non-negative magnitudes used in `sentence()`.
    static func roundToInt(_ x: Double) -> Int {
        Int(x.rounded())
    }
}
