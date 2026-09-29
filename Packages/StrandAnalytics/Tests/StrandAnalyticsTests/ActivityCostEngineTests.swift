import XCTest
@testable import StrandAnalytics

/// ActivityCostEngine — "what each activity costs your recovery". The oracle for the
/// Android ActivityCostEngineTest; keep the two in lockstep (same fixtures, same numbers).
final class ActivityCostEngineTests: XCTestCase {

    // MARK: - Helpers

    private func cost(_ results: [ActivityCost], _ sport: String) -> ActivityCost? {
        results.first { $0.sport == sport }
    }

    // MARK: - Delta sign + value, D+1 keying, baseline excludes active days

    /// "running" tagged on 9 consecutive days, each with a morning Charge of 50; a
    /// separate untouched block averages 70. baselineMean = 70 (the active 50-days are
    /// EXCLUDED), meanNextMorning = 50 (each session day's D+1 is the next 50-morning),
    /// so delta = +20 — a real cost. The last tagged day (06-09) has no D+1 value, so
    /// n = 8 of the 9 tagged days.
    func testDeltaSignAndValueAndBaselineExcludesActive() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        for d in 1...9 {
            let day = String(format: "2026-06-%02d", d)
            tagged.insert(day)
            rec[day] = 50            // each active day's own Charge (excluded from baseline)
        }
        // A block of genuinely untouched rest days, all at 70.
        for d in 20...27 { rec[String(format: "2026-06-%02d", d)] = 70 }

        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["running": tagged],
                                              recoveryByDay: rec)
        let r = cost(out, "running")
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.baselineMean, 70, accuracy: 1e-9)        // active 50-days excluded
        XCTAssertEqual(r!.meanNextMorning, 50, accuracy: 1e-9)     // D+1 keyed
        XCTAssertEqual(r!.delta, 20, accuracy: 1e-9)               // +20 cost
        XCTAssertEqual(r!.n, 8)                                    // 06-09 has no D+1 value
        XCTAssertEqual(r!.confidence, .solid)
    }

    /// Negative delta: the morning after wakes HIGHER than the rest baseline. Six
    /// consecutive tagged days each at 80 (so every D+1 is the next active 80-day and is
    /// excluded from the baseline); a separate untouched block sets baseline = 60.
    func testNegativeDeltaWhenNextMorningAboveBaseline() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        for d in 1...6 {
            let day = String(format: "2026-07-%02d", d)
            tagged.insert(day)
            rec[day] = 80
        }
        for d in 20...25 { rec[String(format: "2026-07-%02d", d)] = 60 }  // baseline 60

        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["yoga": tagged],
                                              recoveryByDay: rec)
        let r = cost(out, "yoga")!
        XCTAssertEqual(r.baselineMean, 60, accuracy: 1e-9)
        XCTAssertEqual(r.meanNextMorning, 80, accuracy: 1e-9)  // 5 D+1s (07-06 has no D+1)
        XCTAssertEqual(r.n, 5)
        XCTAssertEqual(r.delta, -20, accuracy: 1e-9)   // you wake ABOVE baseline
    }

    // MARK: - nil recovery[D+1] is skipped, not counted

    /// 6 tagged days but only 5 have a D+1 Charge value — the missing one is skipped, so
    /// n == 5 (and it does not crash on the absent key).
    func testMissingNextMorningIsSkipped() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        for d in 1...6 {
            let day = String(format: "2026-08-%02d", d)
            tagged.insert(day)
            if d != 3 {   // deliberately leave 2026-08-04 (the D+1 of day 3) absent
                rec[String(format: "2026-08-%02d", d + 1)] = 55
            }
        }
        for d in 20...25 { rec[String(format: "2026-08-%02d", d)] = 65 }

        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["swim": tagged],
                                              recoveryByDay: rec)
        let r = cost(out, "swim")!
        XCTAssertEqual(r.n, 5)                                  // the gap day dropped
        XCTAssertEqual(r.meanNextMorning, 55, accuracy: 1e-9)
        XCTAssertEqual(r.confidence, .building)                // 4 ≤ 5 < 8
    }

    // MARK: - daysToBaseline: dip-then-recover == 3, and nil when never recovers

    // Four session anchors, each the 1st of a different month so the D+1…D+7 forward
    // windows never overlap and there is no month-overflow arithmetic to mirror.
    private let dipAnchors = ["2026-01-01", "2026-03-01", "2026-05-01", "2026-07-01"]

    /// A dip-then-recover trajectory: after a session Charge is 50 (D+1), 55 (D+2), then
    /// back to baseline 70 from D+3 on. baselineMean = 70, tol = 3 → target = 67. traj is
    /// 50, 55, 70, … so the first k with traj[k] ≥ 67 is k = 3.
    func testDaysToBaselineDipThenRecover() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        // Each anchor's D+1/D+2/D+3 — written explicitly (no day arithmetic in the test).
        let plus: [(Int, Double)] = [(1, 50), (2, 55), (3, 70)]
        for anchor in dipAnchors {
            tagged.insert(anchor)
            for (k, v) in plus {
                rec[CorrelationEngine.shiftDay(anchor, by: k)!] = v
            }
        }
        // Rest baseline of 70 on a block of genuinely untouched days.
        for i in 1...8 { rec[String(format: "2026-11-%02d", i)] = 70 }

        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["lift": tagged],
                                              recoveryByDay: rec)
        let r = cost(out, "lift")!
        XCTAssertEqual(r.baselineMean, 70, accuracy: 1e-9)
        XCTAssertEqual(r.daysToBaseline, 3)
        XCTAssertEqual(r.n, 4)   // four anchors, each with a D+1 value
    }

    /// Never climbs back within the 7-day window → daysToBaseline is nil. Charge stays at
    /// 40 for all of D+1…D+7 while the baseline is 70 (target 67).
    func testDaysToBaselineNilWhenNeverRecovers() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        for anchor in dipAnchors {
            tagged.insert(anchor)
            for k in 1...7 {
                rec[CorrelationEngine.shiftDay(anchor, by: k)!] = 40
            }
        }
        for i in 1...8 { rec[String(format: "2026-11-%02d", i)] = 70 }

        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["ruck": tagged],
                                              recoveryByDay: rec)
        let r = cost(out, "ruck")!
        XCTAssertEqual(r.baselineMean, 70, accuracy: 1e-9)
        XCTAssertNil(r.daysToBaseline)
    }

    // MARK: - Confidence gate: n=3 omit / n=5 building / n=8 solid

    /// Build a consecutive run of tagged days at value `val` from `2028-MM-startDay`, so
    /// every interior day's D+1 is the next tagged day (n = length−1). Mornings live on
    /// tagged days, so they never leak into the rest baseline.
    private func run(_ rec: inout [String: Double], _ tagged: inout Set<String>,
                     month: Int, startDay: Int, length: Int, value: Double) {
        for i in 0..<length {
            let day = String(format: "2028-%02d-%02d", month, startDay + i)
            tagged.insert(day)
            rec[day] = value
        }
    }

    func testConfidenceGate() {
        var rec: [String: Double] = [:]
        // Each run of length L yields n = L−1 next-morning pairs.
        var thin: Set<String> = []   // length 4 → n=3 → OMITTED
        run(&rec, &thin, month: 1, startDay: 1, length: 4, value: 50)
        var mid: Set<String> = []    // length 6 → n=5 → .building
        run(&rec, &mid, month: 2, startDay: 1, length: 6, value: 50)
        var big: Set<String> = []    // length 9 → n=8 → .solid
        run(&rec, &big, month: 3, startDay: 1, length: 9, value: 50)
        // A genuinely untouched baseline block (different month, never tagged).
        for i in 1...8 { rec[String(format: "2028-06-%02d", i)] = 70 }

        let out = ActivityCostEngine.evaluate(
            activityDaysBySport: ["thin": thin, "mid": mid, "big": big],
            recoveryByDay: rec)

        XCTAssertNil(cost(out, "thin"))                          // n=3 omitted
        XCTAssertEqual(cost(out, "mid")?.n, 5)
        XCTAssertEqual(cost(out, "mid")?.confidence, .building)  // n=5
        XCTAssertEqual(cost(out, "big")?.n, 8)
        XCTAssertEqual(cost(out, "big")?.confidence, .solid)     // n=8
        XCTAssertEqual(out.count, 2)                             // only mid + big survive
    }

    // MARK: - Ranking: |delta| desc, solid before building, name asc

    func testRanking() {
        // Three surviving sports, all measured against baseline 70:
        //   "alpha":   meanNextMorning 60 → delta 10, n=8 → .solid
        //   "bravo":   meanNextMorning 50 → delta 20, n=5 → .building
        //   "charlie": meanNextMorning 60 → delta 10, n=5 → .building
        // Order: bravo (|20|), then alpha (|10|, solid before building), then charlie.
        var rec: [String: Double] = [:]
        var alpha: Set<String> = []
        run(&rec, &alpha, month: 1, startDay: 1, length: 9, value: 60)   // n=8, delta 10
        var bravo: Set<String> = []
        run(&rec, &bravo, month: 2, startDay: 1, length: 6, value: 50)   // n=5, delta 20
        var charlie: Set<String> = []
        run(&rec, &charlie, month: 3, startDay: 1, length: 6, value: 60) // n=5, delta 10
        for i in 1...8 { rec[String(format: "2028-06-%02d", i)] = 70 }   // baseline 70

        let out = ActivityCostEngine.evaluate(
            activityDaysBySport: ["alpha": alpha, "bravo": bravo, "charlie": charlie],
            recoveryByDay: rec)
        XCTAssertEqual(out.map { $0.sport }, ["bravo", "alpha", "charlie"])
        // Spot-check the deltas the ranking is built on.
        XCTAssertEqual(cost(out, "bravo")!.delta, 20, accuracy: 1e-9)
        XCTAssertEqual(cost(out, "alpha")!.delta, 10, accuracy: 1e-9)
        XCTAssertEqual(cost(out, "charlie")!.delta, 10, accuracy: 1e-9)
    }

    // MARK: - Sentence degradation

    func testSentenceFull() {
        let c = ActivityCost(sport: "running", delta: 12.0, meanNextMorning: 58,
                             baselineMean: 70, daysToBaseline: 2, n: 9, confidence: .solid)
        XCTAssertEqual(c.sentence(),
            "Sessions like this usually cost you about 12 Charge points the next morning "
            + "and take about 2 days to bounce back (n=9).")
    }

    func testSentenceDropsDaysClauseWhenNil() {
        let c = ActivityCost(sport: "running", delta: 12.0, meanNextMorning: 58,
                             baselineMean: 70, daysToBaseline: nil, n: 9, confidence: .solid)
        XCTAssertEqual(c.sentence(),
            "Sessions like this usually cost you about 12 Charge points the next morning (n=9).")
    }

    func testSentenceBarelyMoves() {
        let c = ActivityCost(sport: "walk", delta: 0.4, meanNextMorning: 69.6,
                             baselineMean: 70, daysToBaseline: 1, n: 6, confidence: .building)
        XCTAssertEqual(c.sentence(),
            "Sessions like this barely move your next-day Charge (n=6).")
    }

    func testSentenceLiftDirectionAndSingularDay() {
        // Negative delta → "lift"; daysToBaseline 1 → singular "day".
        let c = ActivityCost(sport: "yoga", delta: -1.0, meanNextMorning: 71,
                             baselineMean: 70, daysToBaseline: 1, n: 8, confidence: .solid)
        XCTAssertEqual(c.sentence(),
            "Sessions like this usually lift about 1 Charge point the next morning "
            + "and take about 1 day to bounce back (n=8).")
    }

    // MARK: - Empty input

    func testEmptyInputs() {
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: [:],
                                                  recoveryByDay: ["2026-01-01": 60]).isEmpty)
        XCTAssertTrue(ActivityCostEngine.evaluate(activityDaysBySport: ["run": ["2026-01-01"]],
                                                  recoveryByDay: [:]).isEmpty)
    }

    /// All days are tagged (no untouched rest days) → no baseline → empty result.
    func testNoRestDaysYieldsEmpty() {
        var rec: [String: Double] = [:]
        var tagged: Set<String> = []
        for d in 1...8 {
            let day = String(format: "2026-05-%02d", d)
            tagged.insert(day)
            rec[day] = 50
        }
        // Every recovery day is also a tagged day → activeUnion covers them all.
        let out = ActivityCostEngine.evaluate(activityDaysBySport: ["run": tagged],
                                              recoveryByDay: rec)
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Stat helper

    func testMean() {
        XCTAssertEqual(ActivityCostEngine.mean([2, 4, 6]), 4, accuracy: 1e-9)
        XCTAssertEqual(ActivityCostEngine.mean([]), 0, accuracy: 1e-9)
    }
}
