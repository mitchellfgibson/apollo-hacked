import XCTest
@testable import WhoopProtocol

/// Real captured GET_DATA_RANGE frames (from ryanbr/noop's DataRangeTests / Whoop5CommandResponseTests,
/// all CRC-valid). One WHOOP 4.0 COMMAND_RESPONSE, three WHOOP 5.0/MG COMMAND_RESPONSEs, the MG PENDING
/// ack, and the WHOOP 4.0 BLE_REALTIME_HR_OFF EVENT frame that the old frame[6]-only gate misread.
final class DataRangeTests: XCTestCase {

    private func hex(_ s: String) -> [UInt8] {
        stride(from: 0, to: s.count, by: 2).map { off in
            let i = s.index(s.startIndex, offsetBy: off)
            return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
        }
    }

    // WHOOP 4.0 COMMAND_RESPONSE (type 36), 80 bytes, cmdOff 6.
    private let w4 = "aa4c00a7247e220a01010000000050070100a307010050070100000000000000020035030000"
        + "c2fc13008046394b00000000bbe1636aa02d0000bbe1636aa02d0000c6e4636ac07c000000000447ea04"
    // WHOOP 5.0/MG COMMAND_RESPONSE (type 36), 84 bytes, cmdOff 10.
    private let mgA = "aa014c00010032d124cc22040101c0890100b4890100b6890100b4890100110000000000020012000000"
        + "e2ff1d00785ac169707d0000edeb626a5c0f0000edeb626a5c0f0000feeb626a5c0f00000000a7c3ec16"
    private let mgC = "aa014c00010032d124982207010180b901005ab7010048b901005ab701001000000000000200"
        + "da1b00000ee31d00b0e1ff69d7430000a3ab266a3d4a0000a3ab266a3d4a00007cc7266a5c4f00000000623977f5"
    private let mgPending = "aa010c000100271124e8220402000000c391bc3d"
    // WHOOP 4.0 EVENT (type 48) for BLE_REALTIME_HR_OFF: byte 6 is the EVENT NUMBER 34, not a command.
    private let w4Event = "aa100057305d22009968526a083900001d2e2263"

    private let now = 1_790_000_000

    func testWhoop4Window() {
        guard let off = DataRange.responseCommandOffset(in: hex(w4), family: .whoop4) else {
            return XCTFail("should be recognised")
        }
        XCTAssertEqual(off, 6)
        guard case .window(let w) = DataRange.parse(hex(w4), cmdOff: off, now: now) else {
            return XCTFail("should decode")
        }
        XCTAssertNil(w.oldest)                       // 2010-01-01 sentinel → unknown, not a date
        XCTAssertEqual(w.cursor, 1_784_930_747)
        XCTAssertEqual(w.newest, 1_784_931_526)
        XCTAssertEqual(w.pagesBehind, 83)            // matches upstream's hardware-pinned value
    }

    func testWhoop5Windows() {
        guard let off = DataRange.responseCommandOffset(in: hex(mgC), family: .whoop5) else {
            return XCTFail("should be recognised")
        }
        XCTAssertEqual(off, 10)
        guard case .window(let w) = DataRange.parse(hex(mgC), cmdOff: off, now: now) else {
            return XCTFail("should decode")
        }
        // The two values upstream asserts for this exact frame (history_oldest / history_newest).
        XCTAssertEqual(w.oldest, 1_778_377_136)
        XCTAssertEqual(w.newest, 1_780_926_332)
        XCTAssertEqual(w.cursor, 1_780_919_203)
        XCTAssertEqual(w.pagesBehind, 494)

        guard case .window(let a) = DataRange.parse(hex(mgA), cmdOff: 10, now: now) else {
            return XCTFail("should decode")
        }
        XCTAssertEqual(a.oldest, 1_774_279_288)
        XCTAssertEqual(a.newest, 1_784_867_838)
        XCTAssertEqual(a.pagesBehind, 2)
    }

    func testPendingAckIsNotAFailure() {
        XCTAssertEqual(DataRange.responseCommandOffset(in: hex(mgPending), family: .whoop5), 10)
        XCTAssertEqual(DataRange.parse(hex(mgPending), cmdOff: 10, now: now), .pending)
    }

    /// The EVENT frame the old frame[6] gate accepted is now rejected before any decode.
    func testEventFrameIsNotADataRangeResponse() {
        XCTAssertNil(DataRange.responseCommandOffset(in: hex(w4Event), family: .whoop4))
    }

    /// A truncated / unknown-firmware SUCCESS frame fails closed with a reason, never a date.
    func testShortSuccessFrameIsUnrecognised() {
        let short = hex("aa014c00010032d124e92204010100bf0000b4be0000c1be0000b4be00000c000000000002008f00")
        guard case .unrecognised = DataRange.parse(short, cmdOff: 10, now: now) else {
            return XCTFail("a short frame must not decode")
        }
    }

    /// A frame whose fixed slots are not plausible unix times is refused rather than reported.
    func testImplausibleWordsAreRefused() {
        var frame = hex(mgC)
        for k in 0..<4 { frame[10 + 4 + 14 * 4 + k] = 0xFF }   // clobber V(14)
        guard case .unrecognised = DataRange.parse(frame, cmdOff: 10, now: now) else {
            return XCTFail("clobbered newest must not decode")
        }
    }

    /// A newest dated far in the future (strap RTC set ahead) is refused, not latched.
    func testFutureNewestIsRefused() {
        guard case .unrecognised = DataRange.parse(hex(mgC), cmdOff: 10, now: 1_600_000_000) else {
            return XCTFail("future-dated newest must not decode")
        }
    }
}
