import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests for SedentaryDetector — the pure core of the inactivity reminder. The detection tests mirror
/// the Android ActivityDetectorTest; the decision tests cover the live-path guard (fires after the
/// threshold; not inside cooldown; not outside active hours; resets on movement; respects the toggle).
/// Fixtures are IDENTICAL to SedentaryDetectorTest.kt so the two engines prove byte-identical output.
final class SedentaryDetectorTests: XCTestCase {

    // Cadence ~3 s (close to real offload data) so the 240 s smoothing window behaves realistically.
    private let cad = 3

    /// A sample at second `sec` with gravity (x, 0, 1).
    private func gravS(_ sec: Int, _ x: Double) -> GravitySample {
        GravitySample(ts: sec, x: x, y: 0, z: 1)
    }

    // ── Detection (ActivityDetector parity) ───────────────────────────────────

    func testEmptyOrSingle_yieldsNothing() {
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts([]).isEmpty)
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts([gravS(0, 0)]).isEmpty)
    }

    func testSittingThenWalking_yieldsOneBoutEndingAtTheWalk() {
        var g: [GravitySample] = []
        var t = 0
        // 30 min "sitting": tiny wrist motion (~0.02 g deltas) — below the move threshold.
        while t <= 30 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        // then 8 min "walking": large sustained deltas (~0.5 g) — above the threshold.
        while t <= 38 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.5)); t += cad }

        let bouts = SedentaryDetector.detectSedentaryBouts(g)
        XCTAssertEqual(bouts.count, 1)
        XCTAssertEqual(bouts[0].start, 0)
        // Bout ends shortly after the sit→walk boundary (the smoothed signal takes ~1–2 min to cross).
        XCTAssertTrue(bouts[0].end >= 27 * 60 && bouts[0].end <= 34 * 60,
                      "bout should end ~30min, got \(bouts[0].end / 60)")
    }

    func testIsolatedReachesDoNotFragmentIt() {
        // Mostly tiny motion with two isolated big "reaches" — the smoothed signal averages them down,
        // so the sedentary bout stays whole (reaching for coffee shouldn't reset the timer).
        var g: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 {
            let reach = (t == 10 * 60 || t == 20 * 60)
            g.append(gravS(t, reach ? 1.0 : ((t / cad) % 2 == 0 ? 0.0 : 0.02)))
            t += cad
        }
        XCTAssertEqual(SedentaryDetector.detectSedentaryBouts(g).count, 1,
                       "isolated reaches shouldn't fragment the sedentary bout")
    }

    func testContinuousWalking_yieldsNothing() {
        var g: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.5)); t += cad }
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts(g).isEmpty,
                      "continuous walking is never sedentary")
    }

    func testShortStretchUnderMinMinutes_dropped() {
        // ~10 min sitting then walking → under the 15-min detector default → no bout.
        var g: [GravitySample] = []
        var t = 0
        while t <= 10 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        while t <= 20 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.5)); t += cad }
        XCTAssertTrue(SedentaryDetector.detectSedentaryBouts(g).isEmpty,
                      "a <15min stretch shouldn't count")
    }

    // ── Pure time helpers (InactivityPrefs parity) ────────────────────────────

    // epochSec for `hour:min` local when tz offset is 0.
    private func atLocal(_ hour: Int, _ min: Int = 0) -> Int { hour * 3600 + min * 60 }

    func testLocalMinuteOfDay_mapsInstantToLocalMinute() {
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(atLocal(8), tzOffsetSec: 0), 8 * 60)
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(atLocal(14), tzOffsetSec: 0), 14 * 60)
        // A UTC 08:00 instant in UTC+1 reads as 09:00 local.
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(atLocal(8), tzOffsetSec: 3600), 9 * 60)
        // Negative offset wraps correctly (UTC 00:30 in UTC-1 → 23:30 the previous local day).
        XCTAssertEqual(SedentaryDetector.localMinuteOfDay(atLocal(0, 30), tzOffsetSec: -3600), 23 * 60 + 30)
    }

    func testWindowContains_handlesWrapAround() {
        // 9–17 straight window.
        XCTAssertTrue(SedentaryDetector.windowContains(14 * 60, startMin: 9 * 60, endMin: 17 * 60))
        XCTAssertFalse(SedentaryDetector.windowContains(8 * 60, startMin: 9 * 60, endMin: 17 * 60))
        // 22:00–07:00 window (crosses midnight): 23:00 inside, 10:00 outside.
        XCTAssertTrue(SedentaryDetector.windowContains(23 * 60, startMin: 22 * 60, endMin: 7 * 60))
        XCTAssertFalse(SedentaryDetector.windowContains(10 * 60, startMin: 22 * 60, endMin: 7 * 60))
    }

    // ── Decision / live-path guard ─────────────────────────────────────────────

    // The current sitting bout is "current": its end equals the newest sample, so newest-end == 0 ≤ maxGapS.
    func testFiresAfterIdleThreshold() {
        // 30 min of pure sitting → a single ≥15-min bout ending at the newest sample (still seated).
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, reNudgeMinutes: 30, buzzLoops: 3,
                                  activeHoursEnabled: false, quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldBuzz, "a 30-min current sedentary bout past the 15-min threshold should buzz")
        XCTAssertEqual(d.buzzLoops, 3)
        XCTAssertEqual(d.nextState.lastBuzzAt, newest)
        XCTAssertEqual(d.nextState.lastBuzzedBoutStart, 0)
        XCTAssertEqual(d.nextState.lastProcessedGravityTs, newest)
    }

    func testDoesNotFireUnderThreshold() {
        // 10 min sitting < 15-min threshold → no bout → no buzz.
        var sit: [GravitySample] = []
        var t = 0
        while t <= 10 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz)
    }

    func testDoesNotFireInsideCooldown() {
        // Same continuing bout buzzed 10 min ago; re-nudge is 30 min → still in cooldown → no buzz.
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, reNudgeMinutes: 30,
                                  activeHoursEnabled: false, quietHoursEnabled: false, onlyWhenWorn: false)
        // Last buzz 10 min before now, for THIS bout (start 0 ≤ lastBuzzedBoutEnd, so it "continues").
        let prior = SedentaryState(lastProcessedGravityTs: 0, lastBuzzAt: newest - 10 * 60,
                                   lastBuzzedBoutStart: 0, lastBuzzedBoutEnd: newest)
        let d = SedentaryDetector.evaluate(sit, state: prior, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "still inside the 30-min re-nudge cooldown")

        // ...but 31 min later the same bout re-nudges.
        let later = SedentaryState(lastProcessedGravityTs: 0, lastBuzzAt: newest - 31 * 60,
                                   lastBuzzedBoutStart: 0, lastBuzzedBoutEnd: newest)
        let d2 = SedentaryDetector.evaluate(sit, state: later, config: cfg,
                                            worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertTrue(d2.shouldBuzz, "past the re-nudge cadence the continuing bout buzzes again")
    }

    func testDoesNotFireOutsideActiveHours() {
        // A 30-min bout whose end maps to 08:00 local; active window is 09:00–17:00 → excluded.
        // Anchor the window so the bout end == 08:00. Sitting starts at 07:30, ends 08:00.
        let base = atLocal(7, 30)
        var sit: [GravitySample] = []
        var t = base
        while t <= base + 30 * 60 { sit.append(gravS(t, ((t - base) / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()! // == 08:00 local
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: true,
                                  activeStartMinutes: 9 * 60, activeEndMinutes: 17 * 60,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "a bout ending 08:00 is outside the 09:00–17:00 active window")

        // Same shape anchored to 14:00 IS inside the window → buzzes.
        let base2 = atLocal(13, 30)
        var sit2: [GravitySample] = []
        var t2 = base2
        while t2 <= base2 + 30 * 60 { sit2.append(gravS(t2, ((t2 - base2) / cad) % 2 == 0 ? 0.0 : 0.02)); t2 += cad }
        let newest2 = sit2.map { $0.ts }.max()! // == 14:00 local
        let d2 = SedentaryDetector.evaluate(sit2, state: .initial, config: cfg,
                                            worn: true, nowSec: newest2, tzOffsetSec: 0)
        XCTAssertTrue(d2.shouldBuzz, "a bout ending 14:00 is inside the active window")
    }

    func testResetsOnDetectedMovement() {
        // The bout ended (the user walked), so its end is far behind the newest sample → not current.
        // 30 min sitting then 10 min walking; newest is at the end of the walk, bout end ~30 min, gap
        // (newest - boutEnd) ~10 min > maxGapS? maxGapS is 20 min, so we use a longer walk to exceed it.
        var g: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        while t <= 55 * 60 { g.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.5)); t += cad } // 25-min walk > 20-min maxGapS
        let newest = g.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(g, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "the user got up and walked — the stale bout must not re-buzz")
    }

    func testRespectsDisabledFlag() {
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: false, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "disabled → never buzz")
        XCTAssertEqual(d.nextState, .initial, "disabled leaves state untouched")
    }

    func testRespectsNotificationMasterOff() {
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: false,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "master notification switch off → inert")
    }

    func testRespectsOnlyWhenWorn() {
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: true)
        let d = SedentaryDetector.evaluate(sit, state: .initial, config: cfg,
                                           worn: false, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "only-when-worn on + strap off → no buzz")
    }

    func testReplayedOffloadDoesNotReBuzz() {
        // The newest gravity ts hasn't advanced past lastProcessedGravityTs → a no-op (idempotent sync).
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, activeHoursEnabled: false,
                                  quietHoursEnabled: false, onlyWhenWorn: false)
        let prior = SedentaryState(lastProcessedGravityTs: newest)
        let d = SedentaryDetector.evaluate(sit, state: prior, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertFalse(d.shouldBuzz, "a replayed / no-new-rows offload can't re-buzz")
        XCTAssertEqual(d.nextState, prior, "no advance → state unchanged")
    }

    func testNewBoutAfterMovementAlertsImmediately() {
        // A fresh, distinct bout (starts after the last buzzed bout's end) alerts even within the
        // re-nudge window, because it is NOT a continuation.
        var sit: [GravitySample] = []
        var t = 0
        while t <= 30 * 60 { sit.append(gravS(t, (t / cad) % 2 == 0 ? 0.0 : 0.02)); t += cad }
        let newest = sit.map { $0.ts }.max()!
        let cfg = SedentaryConfig(enabled: true, notificationsMasterOn: true,
                                  thresholdMinutes: 15, reNudgeMinutes: 30,
                                  activeHoursEnabled: false, quietHoursEnabled: false, onlyWhenWorn: false)
        // Last buzz was 5 min ago but for a PRIOR bout that ended well before this one started (start 0
        // > lastBuzzedBoutEnd would mean new; here we make the prior bout end negative-relative).
        let prior = SedentaryState(lastProcessedGravityTs: 0, lastBuzzAt: newest - 5 * 60,
                                   lastBuzzedBoutStart: -1000, lastBuzzedBoutEnd: -1) // ended before ts 0
        let d = SedentaryDetector.evaluate(sit, state: prior, config: cfg,
                                           worn: true, nowSec: newest, tzOffsetSec: 0)
        XCTAssertTrue(d.shouldBuzz, "a distinct new bout alerts on its own crossing, ignoring cooldown")
    }
}
