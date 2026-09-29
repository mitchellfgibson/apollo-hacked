import XCTest
@testable import Strand

/// H10 — the honest empty-state caption for a Today recovery-vital tile (`TodayView.emptyVitalCaption`).
///
/// When a vital (HRV / Resting HR / SpO₂ / Respiratory) has no value for TODAY and there's nothing to carry
/// over, the tile reads "After tonight's sleep" instead of a bare "—" beside a lone unit (which looked like
/// a fault). It stays HONEST: only on today — a navigated PAST day with no value keeps the plain unit, since
/// that's missing data the user can't act on now, not a "coming tonight" state. Pure copy/gate, pinned here
/// so the wording and the today-only honesty can't silently regress. Mirrors the Android side.
final class TodayEmptyVitalCaptionTests: XCTestCase {

    func testToday_isTheAfterTonightCopy() {
        XCTAssertEqual(TodayView.emptyVitalCaption(unit: "ms", isToday: true), "After tonight's sleep")
    }

    func testToday_copyIsUnitIndependent() {
        // The honest "when it fills" copy doesn't depend on the unit — every overnight vital reads the same.
        XCTAssertEqual(TodayView.emptyVitalCaption(unit: "bpm", isToday: true), "After tonight's sleep")
        XCTAssertEqual(TodayView.emptyVitalCaption(unit: "SpO₂", isToday: true), "After tonight's sleep")
    }

    func testPastDay_isNil_soAnEmptyOldDayKeepsThePlainUnit() {
        // Honesty: a navigated past day with no vital is missing data, not a "coming tonight" state.
        XCTAssertNil(TodayView.emptyVitalCaption(unit: "ms", isToday: false))
        XCTAssertNil(TodayView.emptyVitalCaption(unit: "rpm", isToday: false))
    }
}
