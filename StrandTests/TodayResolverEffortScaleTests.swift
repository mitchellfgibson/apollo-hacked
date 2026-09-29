import XCTest
import WhoopStore
@testable import Strand

/// #304 — the Today resolver and the #313 Effort-gauge scale logic.
///
/// Resolver: a non-UTC user who sleeps pre-midnight and wakes before the 04:00 logical rollover has the
/// just-finished night banked under the NEW local calendar day, while `logicalDayKey` still points at
/// yesterday. `Repository.resolveToday` must surface the LOCAL-day row in that window, yet keep the #144
/// anti-blank guard (defer to the logical-day row, never blank, when no night is banked yet).
///
/// Effort scale: the hero gauge's value + scale-max must follow the EffortScale toggle (#313) so the arc,
/// number and "of N" caption all read on the selected scale — exactly the inverse of the import boundary's
/// rescale, pinned here so a wrong factor can't ship.
final class TodayResolverEffortScaleTests: XCTestCase {

    /// Build a daily row; only `day` + `totalSleepMin` matter for the resolver.
    private func day(_ key: String, sleepMin: Double?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: 50,
                    strain: 40, exerciseCount: nil)
    }

    // MARK: - #304 resolver

    /// (a) Pre-04:00 non-UTC: local day differs from the logical day AND the local-day row has a banked
    /// night → return the local-calendar-day row, not the previous (logical) night.
    func testPreFourAMPrefersBankedLocalDayRow() {
        let logicalKey = "2026-06-13"   // logical day still points at yesterday
        let localKey   = "2026-06-14"   // wall clock has rolled past midnight
        let rows = [
            day(logicalKey, sleepMin: 400),   // last night (under logical key)
            day(localKey, sleepMin: 430),     // the JUST-finished night (under the new local day)
        ]
        let resolved = Repository.resolveToday(days: rows, logicalKey: logicalKey, localKey: localKey)
        XCTAssertEqual(resolved?.day, localKey,
                       "pre-04:00 should surface the banked local-calendar-day night, not yesterday's")
    }

    /// (b) #144 anti-blank guard: local day differs from logical, but the local-day row has NO banked
    /// night yet (totalSleepMin == nil) → keep deferring to the logical-day row, NEVER blank.
    func testPreFourAMNoBankedNightDefersToLogicalNeverBlank() {
        let logicalKey = "2026-06-13"
        let localKey   = "2026-06-14"
        let rows = [
            day(logicalKey, sleepMin: 400),   // yesterday's banked night
            day(localKey, sleepMin: nil),     // a fresh new-day row with no night banked yet
        ]
        let resolved = Repository.resolveToday(days: rows, logicalKey: logicalKey, localKey: localKey)
        XCTAssertEqual(resolved?.day, logicalKey,
                       "no banked night for the local day yet → defer to the logical-day row (#144)")
        XCTAssertNotNil(resolved, "the resolver must never blank when a logical-day row exists")
    }

    /// With no local-day row at all, the resolver still falls back to the logical-day row.
    func testPreFourAMNoLocalRowDefersToLogical() {
        let logicalKey = "2026-06-13", localKey = "2026-06-14"
        let rows = [day(logicalKey, sleepMin: 400)]
        XCTAssertEqual(Repository.resolveToday(days: rows, logicalKey: logicalKey, localKey: localKey)?.day,
                       logicalKey)
    }

    /// Common daytime case (local == logical): plain logical-day lookup, no special-casing.
    func testDaytimeLocalEqualsLogicalUsesLogicalRow() {
        let key = "2026-06-14"
        let rows = [day("2026-06-13", sleepMin: 400), day(key, sleepMin: 420)]
        XCTAssertEqual(Repository.resolveToday(days: rows, logicalKey: key, localKey: key)?.day, key)
    }

    // MARK: - #313 Effort-gauge scale

    /// On the native 0–100 scale the gauge shows the stored value out of 100.
    func testEffortGaugeValueHundredScale() {
        XCTAssertEqual(UnitFormatter.effortValue(63.0, scale: .hundred), 63.0, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.effortScaleMax(.hundred), "100")
    }

    /// On the WHOOP 0–21 scale the gauge rescales the SAME stored value down by 21/100 and reads "of 21".
    func testEffortGaugeValueWhoopScale() {
        XCTAssertEqual(UnitFormatter.effortValue(100.0, scale: .whoop), 21.0, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.effortValue(50.0, scale: .whoop), 10.5, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.effortScaleMax(.whoop), "21")
    }

    /// The displayed value and the scale max are consistent — a value at the scale max fills the gauge.
    func testEffortGaugeFractionConsistentAcrossScales() {
        // A full-effort day (stored 100) is at the top of BOTH scales: 100/100 and 21/21.
        let hundred = UnitFormatter.effortValue(100.0, scale: .hundred) / 100.0
        let whoop = UnitFormatter.effortValue(100.0, scale: .whoop) / 21.0
        XCTAssertEqual(hundred, whoop, accuracy: 1e-9, "the gauge fraction must be scale-independent")
    }
}
