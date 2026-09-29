import XCTest
@testable import WhoopProtocol

/// Pure-logic tests for the Haptic Clock encoder (#460). These pin the EXACT pulse list for sample
/// times; the Android `HapticClockTest.kt` asserts the same lists so the two platforms buzz identically.
final class HapticClockTests: XCTestCase {
    private typealias P = HapticClock.Pulse

    // Shorthand builders so the expected lists below read like the timing table.
    private func long(_ gap: Int) -> P { P(durationMs: HapticClock.longMs, gapMs: gap) }
    private func short(_ gap: Int) -> P { P(durationMs: HapticClock.shortMs, gapMs: gap) }

    /// 3:25 in 24-hour form: hour 03 (no tens, 3 units) — block — minute 25 (2 tens, 5 units).
    func test0325_24h_exactPulseList() {
        let g = HapticClock.intraGapMs
        let expected: [P] = [
            // hour-tens 0 → nothing; hour-units 3 → three short pulses, last carries the block gap.
            short(g), short(g), short(HapticClock.blockGapMs),
            // minute-tens 2 → two long pulses, last carries the group gap.
            long(g), long(HapticClock.groupGapMs),
            // minute-units 5 → five short pulses; the very last pulse has no trailing gap.
            short(g), short(g), short(g), short(g), short(0),
        ]
        XCTAssertEqual(HapticClock.pulses(hour: 3, minute: 25, is24h: true), expected)
    }

    /// 12-hour mapping: 15:25 → dial reads 3:25, so it must equal the 24h 3:25 list exactly.
    func test1525_12h_mapsTo0325() {
        XCTAssertEqual(
            HapticClock.pulses(hour: 15, minute: 25, is24h: false),
            HapticClock.pulses(hour: 3, minute: 25, is24h: true))
    }

    /// 10:05 in 24-hour form: hour 10 (1 ten, 0 units) — block — minute 05 (0 tens, 5 units).
    /// Exercises a 0 unit digit (hour) and a 0 tens digit (minute) — both emit no pulse.
    func test1005_24h_handlesZeroDigits() {
        let g = HapticClock.intraGapMs
        let expected: [P] = [
            // hour-tens 1 → one long pulse; hour-units 0 → nothing, so this long carries the block gap.
            long(HapticClock.blockGapMs),
            // minute-tens 0 → nothing; minute-units 5 → five short, last with no trailing gap.
            short(g), short(g), short(g), short(g), short(0),
        ]
        XCTAssertEqual(HapticClock.pulses(hour: 10, minute: 5, is24h: true), expected)
    }

    /// Midnight 0:00 in 24-hour form has no nonzero digits — there is nothing to buzz.
    func testMidnight_24h_isEmpty() {
        XCTAssertEqual(HapticClock.pulses(hour: 0, minute: 0, is24h: true), [])
    }

    /// Midnight 0:00 in 12-hour form reads "12:00" → one ten + two units of hour, no minute pulses.
    func testMidnight_12h_readsTwelve() {
        let expected: [P] = [
            // hour-tens 1 → long (group gap); hour-units 2 → two short, the second carries the block gap;
            // both minute groups are 0, so the last hour-units pulse is the final pulse → trimmed to 0.
            long(HapticClock.groupGapMs),
            short(HapticClock.intraGapMs), short(0),
        ]
        XCTAssertEqual(HapticClock.pulses(hour: 0, minute: 0, is24h: false), expected)
    }

    /// Noon stays 12 in 12-hour form (it does not collapse to 0).
    func testNoon_12h_isTwelve() {
        XCTAssertEqual(HapticClock.twelveHour(12), 12)
        XCTAssertEqual(HapticClock.twelveHour(0), 12)
        XCTAssertEqual(HapticClock.twelveHour(13), 1)
        XCTAssertEqual(HapticClock.twelveHour(23), 11)
    }

    /// Out-of-range inputs are clamped, not crashed (the trigger can be driven from a stored pref).
    func testClampsOutOfRange() {
        XCTAssertEqual(
            HapticClock.pulses(hour: 99, minute: 99, is24h: true),
            HapticClock.pulses(hour: 23, minute: 59, is24h: true))
        XCTAssertEqual(
            HapticClock.pulses(hour: -5, minute: -5, is24h: true),
            HapticClock.pulses(hour: 0, minute: 0, is24h: true))
    }
}
