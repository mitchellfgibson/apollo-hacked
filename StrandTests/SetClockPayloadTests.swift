import XCTest
@testable import Strand

/// Pins the dual SET_CLOCK payload forms behind the WHOOP 4 fw-41.17.x clock fix (#120). An un-clocked
/// 41.17.x strap ignores the 8-byte SET_CLOCK form outright (no COMMAND_RESPONSE, RTC unchanged) and
/// latches ONLY the legacy 9-byte `[u32 LE][5 zero]` form; without that form the RTC stays lost and the
/// strap banks no sensor history to flash. Newer firmware is the reverse. sendSetClockBothForms() sends
/// both (legacy gated to WHOOP 4), so either firmware latches. These pin the byte layouts + lengths.
@MainActor
final class SetClockPayloadTests: XCTestCase {

    // 8-byte form: [seconds u32 LE][4 zero subseconds]. Length must be exactly 8.
    func testEightByteFormLayout() {
        let now: UInt32 = 0x11223344
        let p = BLEManager.setClockPayload(now: now)
        XCTAssertEqual(p.count, 8)
        XCTAssertEqual(Array(p[0..<4]), [0x44, 0x33, 0x22, 0x11], "u32 LE seconds")
        XCTAssertEqual(Array(p[4..<8]), [0, 0, 0, 0], "subseconds zeroed")
    }

    // 9-byte legacy form: [seconds u32 LE][5 zero]. Length must be exactly 9 — the wrong length is what
    // distinguishes it for fw 41.17.x. Same seconds bytes as the 8-byte form.
    func testNineByteLegacyFormLayout() {
        let now: UInt32 = 0x11223344
        let p = BLEManager.setClockPayloadLegacy(now: now)
        XCTAssertEqual(p.count, 9)
        XCTAssertEqual(Array(p[0..<4]), [0x44, 0x33, 0x22, 0x11], "u32 LE seconds")
        XCTAssertEqual(Array(p[4..<9]), [0, 0, 0, 0, 0], "five zero pad bytes")
    }

    // Both forms carry the SAME seconds for a given `now`, so whichever the firmware latches sets the
    // same wall time (double-latching is harmless).
    func testBothFormsAgreeOnSeconds() {
        let now: UInt32 = 1_700_000_000
        let a = BLEManager.setClockPayload(now: now)
        let b = BLEManager.setClockPayloadLegacy(now: now)
        XCTAssertEqual(Array(a[0..<4]), Array(b[0..<4]))
    }
}

/// Pins the BLE scan-family fallback rotation (PR#195): a service-filtered scan that finds nothing
/// rotates to the OTHER WHOOP family in case the persisted preference went stale after an update/restore.
final class WhoopModelFallbackTests: XCTestCase {

    func testFallbackRotatesBetweenFamilies() {
        XCTAssertEqual(WhoopModel.whoop4.fallbackScanModel, .whoop5mg)
        XCTAssertEqual(WhoopModel.whoop5mg.fallbackScanModel, .whoop4)
    }

    // Rotating twice returns to the original — the rotation is a clean two-state cycle.
    func testFallbackIsInvolution() {
        XCTAssertEqual(WhoopModel.whoop4.fallbackScanModel.fallbackScanModel, .whoop4)
        XCTAssertEqual(WhoopModel.whoop5mg.fallbackScanModel.fallbackScanModel, .whoop5mg)
    }
}
