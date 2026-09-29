import XCTest
@testable import Strand
import StrandAnalytics

/// #H9 — the Sleep stage-breakdown LOW-CONFIDENCE badge gate (`SleepView.isStagingLowConfidence`).
///
/// The UI badge must agree with the engine's persisted Rest confidence: it flags ONLY the suspicious case
/// — a high-efficiency night (lots of measured sleep) whose deep+REM share is implausibly low, which the
/// EEG-free classifier is far likelier to have mis-staged than a real night with no restorative sleep. It
/// must NOT flag a healthy night, a genuinely fragmented (low-efficiency) night, or an unstaged night. The
/// gate delegates to `ScoreConfidence.rest(...)`, so these pin the UI side against the same thresholds the
/// daily pass uses. Pure → no view, no BLE.
final class SleepStagingConfidenceTests: XCTestCase {

    /// A high-efficiency night with near-zero deep+REM → flagged low-confidence (likely staging miss).
    func testHighEfficiencyLowRestorative_isLowConfidence() {
        // 7h asleep, ~2% restorative, 95% efficiency → well below the 10% restorative floor on a >85%-eff night.
        let asleep = 7.0 * 60.0      // 420 min
        let deep = 4.0, rem = 4.0    // 8 min restorative ≈ 1.9% of asleep
        XCTAssertTrue(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                       efficiency: 0.95))
    }

    /// A healthy night (deep+REM ~45% of asleep) is NEVER flagged — its staging is plausible.
    func testHealthyRestorativeShare_isNotFlagged() {
        let asleep = 7.0 * 60.0
        let deep = 90.0, rem = 100.0   // ~45% restorative
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                        efficiency: 0.95))
    }

    /// A genuinely FRAGMENTED night (low efficiency) legitimately carries less deep/REM, so the floor must
    /// not false-positive there — the badge is only for the high-efficiency-yet-low-restorative case.
    func testLowEfficiencyNight_isNotFlagged_evenWithLowRestorative() {
        let asleep = 5.0 * 60.0
        let deep = 3.0, rem = 3.0      // tiny restorative …
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem,
                                                        efficiency: 0.60))   // … but the night was fragmented
    }

    /// An UNSTAGED night (no deep+REM at all) isn't flagged here — there's no staging split to doubt; its
    /// base Rest confidence already reads honestly (.building from no staged sleep), not a downgrade.
    func testUnstagedNight_isNotFlagged() {
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: 6 * 60, deepMin: 0, remMin: 0,
                                                        efficiency: 0.95))
    }

    /// A zero-asleep night can't be evaluated → never flagged (guard against a divide-by-zero / nonsense).
    func testZeroAsleep_isNotFlagged() {
        XCTAssertFalse(SleepView.isStagingLowConfidence(asleepMin: 0, deepMin: 0, remMin: 0,
                                                        efficiency: 0.95))
    }

    /// The UI gate and the engine agree: where `isStagingLowConfidence` is true, the engine's H9 Rest
    /// overload also downgrades to `.building`. Pins the two surfaces to the same threshold.
    func testAgreesWithEngineRestConfidence() {
        let asleep = 7.0 * 60.0, deep = 4.0, rem = 4.0, eff = 0.95
        let uiFlag = SleepView.isStagingLowConfidence(asleepMin: asleep, deepMin: deep, remMin: rem, efficiency: eff)
        let tier = ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                        asleepSeconds: asleep * 60, restorativeSeconds: (deep + rem) * 60,
                                        efficiency: eff)
        XCTAssertTrue(uiFlag)
        XCTAssertEqual(tier, .building)
    }
}
