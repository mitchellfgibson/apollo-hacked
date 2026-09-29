import XCTest
@testable import StrandAnalytics

/// Locks the hydration goal formula: `roundToNearest(sexBaseline + effortBump, 50)` with
/// effortBump = clamp(round(effort/100 · 700), 0…700). BYTE-PARITY with the Android twin
/// (com.noop.analytics.HydrationGoal) — same Int constants, same round-then-clamp, same integer rounding.
final class HydrationGoalTests: XCTestCase {

    // MARK: - Sex baseline

    func testSexBaseline() {
        XCTAssertEqual(HydrationGoal.baselineForSex("male"), 3700)
        XCTAssertEqual(HydrationGoal.baselineForSex("female"), 2700)
        // Anything else falls to the unspecified baseline — never a guess.
        XCTAssertEqual(HydrationGoal.baselineForSex("nonbinary"), 3200)
        XCTAssertEqual(HydrationGoal.baselineForSex("other"), 3200)
        XCTAssertEqual(HydrationGoal.baselineForSex(""), 3200)
    }

    func testSexBaselineNormalisation() {
        // Case- and whitespace-insensitive, plus the m/f shorthands (matches the Kotlin twin).
        XCTAssertEqual(HydrationGoal.baselineForSex("MALE"), 3700)
        XCTAssertEqual(HydrationGoal.baselineForSex(" Female "), 2700)
        XCTAssertEqual(HydrationGoal.baselineForSex("m"), 3700)
        XCTAssertEqual(HydrationGoal.baselineForSex("F"), 2700)
    }

    // MARK: - Effort bump

    func testEffortBumpNilIsZero() {
        XCTAssertEqual(HydrationGoal.effortBump(effort: nil), 0)
    }

    func testEffortBumpScalesAndRounds() {
        // 0 → 0, 100 → 700 (the cap), 50 → 350.
        XCTAssertEqual(HydrationGoal.effortBump(effort: 0), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: 100), 700)
        XCTAssertEqual(HydrationGoal.effortBump(effort: 50), 350)
        // round(63/100 · 700) = round(441) = 441.
        XCTAssertEqual(HydrationGoal.effortBump(effort: 63), 441)
        // round(1/100 · 700) = round(7) = 7.
        XCTAssertEqual(HydrationGoal.effortBump(effort: 1), 7)
    }

    func testEffortBumpClampsOutputOfRange() {
        // Round FIRST, then clamp the OUTPUT to 0…700 (so >100 / negative efforts saturate at the bounds).
        XCTAssertEqual(HydrationGoal.effortBump(effort: -20), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: 150), 700)
        XCTAssertEqual(HydrationGoal.effortBump(effort: .nan), 0)
        XCTAssertEqual(HydrationGoal.effortBump(effort: .infinity), 0)
    }

    // MARK: - Rounding

    func testRoundToNearest50() {
        XCTAssertEqual(HydrationGoal.roundToNearest(3724, step: 50), 3700)
        XCTAssertEqual(HydrationGoal.roundToNearest(3725, step: 50), 3750)  // half rounds up
        XCTAssertEqual(HydrationGoal.roundToNearest(3700, step: 50), 3700)
    }

    // MARK: - Full goal

    func testDailyGoalNoEffort() {
        // No Effort yet → just the rounded baseline (already a multiple of 50).
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: nil), 3700)
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "female", effort: nil), 2700)
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "other", effort: nil), 3200)
    }

    func testDailyGoalWithEffortRoundsTo50() {
        // male 3700 + round(63/100·700)=441 = 4141 → nearest 50 = 4150.
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: 63), 4150)
        // female 2700 + 350 (effort 50) = 3050, already a multiple of 50.
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "female", effort: 50), 3050)
        // male 3700 + 700 (cap) = 4400.
        XCTAssertEqual(HydrationGoal.dailyGoalML(sex: "male", effort: 100), 4400)
    }

    func testDailyGoalIsAlwaysMultipleOf50() {
        for sex in ["male", "female", "other"] {
            for effort in stride(from: 0.0, through: 100.0, by: 1.0) {
                let goal = HydrationGoal.dailyGoalML(sex: sex, effort: effort)
                XCTAssertEqual(goal % 50, 0,
                               "goal \(goal) for sex=\(sex) effort=\(effort) is not a multiple of 50")
            }
        }
    }

    // MARK: - Display helpers

    func testCardValueString() {
        XCTAssertEqual(HydrationGoal.cardValueString(totalML: 1200, goalML: 3200), "1.2 / 3.2 L")
        XCTAssertEqual(HydrationGoal.cardValueString(totalML: 0, goalML: 3700), "0.0 / 3.7 L")
    }

    func testFractionClamps() {
        XCTAssertEqual(HydrationGoal.fraction(totalML: 1600, goalML: 3200), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HydrationGoal.fraction(totalML: 5000, goalML: 3200), 1.0, accuracy: 1e-9)  // capped
        XCTAssertEqual(HydrationGoal.fraction(totalML: 100, goalML: 0), 0.0, accuracy: 1e-9)       // guard
    }

    func testQuickAmounts() {
        XCTAssertEqual(HydrationGoal.sipML, 30)
        XCTAssertEqual(HydrationGoal.cupML, 237)
        XCTAssertEqual(HydrationGoal.bottleML, 500)
    }
}
