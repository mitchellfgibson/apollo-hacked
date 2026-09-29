import XCTest
@testable import Strand

/// #527 — the unscored Effort/Rest "it's coming, not broken" caption on the Today home card.
///
/// When today's Rest or Effort score is genuinely still building, the tile shows a short hint in
/// place of a lone "—" so a fresh/calibrating user reads "coming" rather than "broken". It stays
/// HONEST: only on today (offset 0) — a navigated past day with no score is missing data, not
/// mid-calibration, so it keeps the bare dash. Mirrors the Charge tile's "Calibrating N of 4"
/// today-only treatment and the Android `buildingHint`. Pure copy/gate, pinned here so the wording
/// and the today-only honesty can't silently regress.
final class TodayBuildingHintTests: XCTestCase {

    func testRest_today_isTheWearItTonightCopy() {
        XCTAssertEqual(TodayView.buildingHintCopy(.rest, isToday: true), "Building, wear it tonight")
    }

    func testEffort_today_isTheMovesAsYouDoCopy() {
        XCTAssertEqual(TodayView.buildingHintCopy(.effort, isToday: true), "Building, moves as you do")
    }

    func testPastDay_isNil_soAnUnscoredOldDayStaysABareDash() {
        // Honesty: a navigated past day with no score is missing data, not mid-calibration.
        XCTAssertNil(TodayView.buildingHintCopy(.rest, isToday: false))
        XCTAssertNil(TodayView.buildingHintCopy(.effort, isToday: false))
    }

    func testOtherMetrics_nil_onlyEffortAndRestGetTheHint() {
        // Charge owns its own "Calibrating N of 4" treatment; other tiles never show this hint.
        XCTAssertNil(TodayView.buildingHintCopy(.charge, isToday: true))
        XCTAssertNil(TodayView.buildingHintCopy(.hrv, isToday: true))
    }

    func testCopy_hasNoEmDash() {
        // House style: user-facing strings carry no em-dashes.
        for metric in [KeyMetric.rest, KeyMetric.effort] {
            let hint = TodayView.buildingHintCopy(metric, isToday: true)
            XCTAssertNotNil(hint)
            XCTAssertFalse(hint!.contains("\u{2014}"), "buildingHintCopy(\(metric)) must not contain an em-dash")
        }
    }
}
