import XCTest
@testable import Strand

/// Pins the pure caffeine half-life decay math + the honesty rules of the active estimate (#526). All
/// headless — no UI, no BLE — so it runs in the app-hosted unit bundle. The point of these tests is to
/// hold the line on HONEST DATA: an unknown dose stays unknown (never invented), a future-dated log can't
/// amplify a dose, and the estimate is a deterministic function of what was logged.
final class CaffeineDecayTests: XCTestCase {

    private let hl = CaffeineDecay.defaultHalfLifeHours   // 5.5 h

    // MARK: - fractionRemaining

    func testFractionAtZeroIsFull() {
        XCTAssertEqual(CaffeineDecay.fractionRemaining(hoursElapsed: 0, halfLifeHours: hl), 1.0, accuracy: 1e-9)
    }

    func testFractionAtOneHalfLifeIsHalf() {
        XCTAssertEqual(CaffeineDecay.fractionRemaining(hoursElapsed: hl, halfLifeHours: hl), 0.5, accuracy: 1e-9)
    }

    func testFractionAtTwoHalfLivesIsQuarter() {
        XCTAssertEqual(CaffeineDecay.fractionRemaining(hoursElapsed: 2 * hl, halfLifeHours: hl), 0.25, accuracy: 1e-9)
    }

    func testNegativeElapsedClampsToFull() {
        // A future-dated log must NOT amplify the dose (no fraction > 1).
        XCTAssertEqual(CaffeineDecay.fractionRemaining(hoursElapsed: -3, halfLifeHours: hl), 1.0, accuracy: 1e-9)
    }

    func testZeroHalfLifeYieldsZero() {
        XCTAssertEqual(CaffeineDecay.fractionRemaining(hoursElapsed: 1, halfLifeHours: 0), 0.0, accuracy: 1e-9)
    }

    // MARK: - remainingMg / totals

    func testRemainingMgHalvesEachHalfLife() {
        XCTAssertEqual(CaffeineDecay.remainingMg(doseMg: 200, hoursElapsed: hl, halfLifeHours: hl), 100, accuracy: 1e-6)
        XCTAssertEqual(CaffeineDecay.remainingMg(doseMg: 200, hoursElapsed: 2 * hl, halfLifeHours: hl), 50, accuracy: 1e-6)
    }

    func testTotalRemainingMgSumsDoses() {
        let total = CaffeineDecay.totalRemainingMg(
            [(doseMg: 100, hoursElapsed: 0), (doseMg: 80, hoursElapsed: hl)], halfLifeHours: hl)
        XCTAssertEqual(total, 100 + 40, accuracy: 1e-6)   // 100 full + 80 halved
    }

    func testHoursUntilQuarterIsTwoHalfLives() {
        XCTAssertEqual(CaffeineDecay.hoursUntilFraction(0.25, halfLifeHours: hl), 2 * hl, accuracy: 1e-6)
    }

    func testIsStillActiveThreshold() {
        // At 1 half-life, 50% remains (> 25%) → active. At 3 half-lives, 12.5% remains → not active.
        XCTAssertTrue(CaffeineDecay.isStillActive(hoursElapsed: hl, halfLifeHours: hl))
        XCTAssertFalse(CaffeineDecay.isStillActive(hoursElapsed: 3 * hl, halfLifeHours: hl))
    }

    // MARK: - CaffeineActiveEstimate (the honest summary)

    func testEstimateSumsOnlyKnownDoses() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let intakes = [
            CaffeineIntake(at: now, mg: 120),                                    // full
            CaffeineIntake(at: now.addingTimeInterval(-hl * 3600), mg: nil),     // active, dose UNKNOWN
        ]
        let est = CaffeineActiveEstimate.compute(intakes: intakes, now: now, halfLifeHours: hl)
        XCTAssertEqual(est.activeIntakeCount, 2)
        // The mg total reflects ONLY the known-dose intake — the unknown one is never invented as a number.
        XCTAssertEqual(est.totalRemainingMg!, 120, accuracy: 1e-6)
    }

    func testEstimateNoKnownDoseYieldsNilMg() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let est = CaffeineActiveEstimate.compute(intakes: [CaffeineIntake(at: now, mg: nil)], now: now, halfLifeHours: hl)
        XCTAssertTrue(est.hasActive)
        XCTAssertNil(est.totalRemainingMg)   // honest: active but amount unknown → no fabricated mg
    }

    func testEstimateExcludesClearedAndFutureIntakes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let intakes = [
            CaffeineIntake(at: now.addingTimeInterval(-10 * hl * 3600), mg: 200),  // long cleared
            CaffeineIntake(at: now.addingTimeInterval(+2 * 3600), mg: 200),        // future-dated
            CaffeineIntake(at: now, mg: 200),                                      // active
        ]
        let est = CaffeineActiveEstimate.compute(intakes: intakes, now: now, halfLifeHours: hl)
        XCTAssertEqual(est.activeIntakeCount, 1)
        XCTAssertEqual(est.totalRemainingMg!, 200, accuracy: 1e-6)
    }

    func testEstimateEmptyIntakesIsInactive() {
        let est = CaffeineActiveEstimate.compute(intakes: [], now: Date(), halfLifeHours: hl)
        XCTAssertFalse(est.hasActive)
        XCTAssertEqual(est.activeIntakeCount, 0)
        XCTAssertNil(est.totalRemainingMg)
    }

    func testMostRecentActiveHoursPicksClosest() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let intakes = [
            CaffeineIntake(at: now.addingTimeInterval(-2 * 3600), mg: 100),
            CaffeineIntake(at: now.addingTimeInterval(-1 * 3600), mg: 100),   // most recent
        ]
        let est = CaffeineActiveEstimate.compute(intakes: intakes, now: now, halfLifeHours: hl)
        XCTAssertEqual(est.hoursSinceMostRecentActive!, 1.0, accuracy: 1e-6)
    }

    // MARK: - Store (UserDefaults-backed, opt-in, sanitising)

    @MainActor
    private func freshStore(now: Date) -> CaffeineLogStore {
        let suite = UserDefaults(suiteName: "caffeine.test.\(UUID().uuidString)")!
        return CaffeineLogStore(defaults: suite, now: { now })
    }

    @MainActor
    func testStoreStartsEmptyAndLogs() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = freshStore(now: now)
        XCTAssertTrue(store.intakes.isEmpty)            // opt-in: nothing until the user logs
        store.log(at: now, mg: 95)
        XCTAssertEqual(store.intakes.count, 1)
        XCTAssertEqual(store.intakes.first?.mg, 95)
    }

    @MainActor
    func testStoreSanitisesBadMgToUnknown() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = freshStore(now: now)
        // Distinct timestamps so the newest-first ordering is deterministic.
        store.log(at: now.addingTimeInterval(-180), mg: -50)   // negative → unknown, not garbage
        store.log(at: now.addingTimeInterval(-120), mg: .nan)  // non-finite → unknown
        store.log(at: now.addingTimeInterval(-60), mg: 999999) // absurd → clamped
        // Look each intake up by its known time rather than relying on array index.
        func mg(at offset: TimeInterval) -> Double?? {
            store.intakes.first { $0.at == now.addingTimeInterval(offset) }?.mg
        }
        XCTAssertEqual(mg(at: -180), .some(nil))     // -50 stored as unknown
        XCTAssertEqual(mg(at: -120), .some(nil))     // nan stored as unknown
        XCTAssertEqual(mg(at: -60), .some(2000))     // clamped upper bound
    }

    @MainActor
    func testStorePrunesOldIntakesOnLoad() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let suite = UserDefaults(suiteName: "caffeine.test.\(UUID().uuidString)")!
        let writer = CaffeineLogStore(defaults: suite, now: { now })
        writer.log(at: now.addingTimeInterval(-100 * 3600), mg: 100)   // older than retention
        writer.log(at: now, mg: 100)
        // A fresh store over the same suite prunes the stale one on load.
        let reader = CaffeineLogStore(defaults: suite, now: { now })
        XCTAssertEqual(reader.intakes.count, 1)
    }

    @MainActor
    func testStoreEstimateReflectsLoggedIntakes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = freshStore(now: now)
        store.log(at: now, mg: 160)
        XCTAssertTrue(store.estimate().hasActive)
        XCTAssertEqual(store.estimate().totalRemainingMg!, 160, accuracy: 1e-6)
        store.clearAll()
        XCTAssertFalse(store.estimate().hasActive)
    }

    // MARK: - Cutoff window (PR#566) — parity with the Kotlin CaffeineCutoffTest

    func testCutoffLeadIsTwoHalfLivesForQuarterResidual() {
        XCTAssertEqual(CaffeineDecay.cutoffLeadHours(), 2 * hl, accuracy: 1e-9)
    }

    func testCutoffIsBedtimeMinusLead() {
        // Bedtime 23:00 (1380), lead 11 h → cutoff 12:00 (720).
        let bed = 23 * 60
        let expected = bed - Int(2 * hl * 60)
        XCTAssertEqual(CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes: bed), expected)
    }

    func testEarlyBedtimeWrapsToPreviousEvening() {
        // Bedtime 09:00 (540): 540 - 660 = -120 → normalised to 22:00 (1320).
        XCTAssertEqual(CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes: 9 * 60), 1320)
    }

    func testMorningCoffeeIsNotLateAndAfternoonIs() {
        XCTAssertFalse(CaffeineDecay.isPastCutoff(intakeMinutes: 8 * 60, bedtimeMinutes: 23 * 60))
        XCTAssertTrue(CaffeineDecay.isPastCutoff(intakeMinutes: 16 * 60, bedtimeMinutes: 23 * 60))
    }

    func testIntakeExactlyAtCutoffIsNotLate() {
        let bed = 23 * 60
        let cutoffRaw = bed - Int(2 * hl * 60)
        XCTAssertFalse(CaffeineDecay.isPastCutoff(intakeMinutes: cutoffRaw, bedtimeMinutes: bed))
        XCTAssertTrue(CaffeineDecay.isPastCutoff(intakeMinutes: cutoffRaw + 1, bedtimeMinutes: bed))
    }
}
