import XCTest
@testable import WhoopProtocol

final class DeviceFamilyFramingTests: XCTestCase {

    // MARK: - Whoop 5.0 command framing (puffinCommandFrame) — locked to ground truth

    /// A 4-aligned command needs no padding and must verify as a well-formed puffin frame.
    func testPuffinCommandFrameAligned() {
        // SEND_HISTORICAL_DATA (cmd 22) payload [0]: inner [35,1,22,0] is already 4-aligned.
        let built = puffinCommandFrame(cmd: 22, seq: 1, payload: [0x00])
        XCTAssertEqual(built, Self.hex("aa0108000001e671230116002c00998e"))
        XCTAssertTrue(verifyFrame(built, family: .whoop5).ok)
    }

    /// THE PADDING FIX: the 12-byte maverick haptic payload makes the inner record 15 bytes, which
    /// MUST be padded to 16 before the length/CRC are computed — otherwise the strap rejects the
    /// frame (it was ACK'd-but-silent before this fix). Round-trips through verifyFrame.
    func testPuffinCommandFramePads12ByteHaptic() {
        let buzz = MaverickHaptics.notificationBuzz(loops: 1)   // 12 bytes
        XCTAssertEqual(buzz.count, 12)
        let built = puffinCommandFrame(cmd: 19, seq: 5, payload: buzz)
        XCTAssertEqual(built, Self.hex("aa0114000001e1e1230513012f9800000000000000000100ba9fe436"))
        XCTAssertTrue(verifyFrame(built, family: .whoop5).ok, "padded frame must verify")
    }

    static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            out.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return out
    }

    // MARK: - CRC16-Modbus known vectors

    func testCrc16ModbusKnownVectors() {
        // The canonical CRC16/MODBUS check value for the ASCII string "123456789".
        XCTAssertEqual(crc16Modbus(Array("123456789".utf8)), 0x4B37)
        // Empty input returns the init value unchanged.
        XCTAssertEqual(crc16Modbus([]), 0xFFFF)
        // Classic Modbus RTU frame 01 04 02 FF FF -> CRC bytes B8 80 (LE) = value 0x80B8.
        XCTAssertEqual(crc16Modbus([0x01, 0x04, 0x02, 0xFF, 0xFF]), 0x80B8)
        // Single-byte vectors.
        XCTAssertEqual(crc16Modbus([0xAA]), 0x3F3F)
        XCTAssertEqual(crc16Modbus(Array("A".utf8)), 0x707F)
    }

    // MARK: - Whoop 5.0 frame verification

    // Synthetic, hand-computed VALID whoop5 frame:
    //   header  = [aa 01 0c 00 00 01]            (SOF, format, len=12 LE, two header bytes)
    //   crc16   = e741  (CRC16-Modbus over the 6 header bytes, LE)
    //   payload = [36 07 02 11 22 33 44 55]      (type=COMMAND_RESPONSE, seq=7, cmd=2, data)
    //   crc32   = 7481f36e  (zlib CRC32 over payload, LE) -> value 0x6ef38174
    static let validWhoop5 = "aa010c000001e74124070211223344557481f36e"

    func testVerifyValidWhoop5Frame() {
        let frame = Self.hex(Self.validWhoop5)
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 12)        // declaredLength = payload(8) + crc32(4)
        XCTAssertEqual(check.crc8OK, true)      // header CRC16 outcome surfaced via crc8OK
        XCTAssertEqual(check.crc32OK, true)
    }

    func testWhoop4OnWhoop5FrameFailsHeaderCRC() {
        // Same bytes, parsed as whoop4: the CRC8 path reads length/crc8 from the wrong offsets,
        // so the header CRC must fail — proving the family switch genuinely changes behaviour.
        let frame = Self.hex(Self.validWhoop5)
        let check = verifyFrame(frame, family: .whoop4)
        XCTAssertEqual(check.crc8OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5HeaderCorruptionDetected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[4] ^= 0xFF   // corrupt a header byte covered by the CRC16
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertEqual(check.crc8OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5PayloadCorruptionDetected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[10] ^= 0xFF  // corrupt a payload byte -> crc32 fails, header crc16 still OK
        let check = verifyFrame(frame, family: .whoop5)
        XCTAssertEqual(check.crc8OK, true)
        XCTAssertEqual(check.crc32OK, false)
        XCTAssertFalse(check.ok)
    }

    func testWhoop5ShortFrameRejected() {
        XCTAssertFalse(verifyFrame([0xAA, 0x01, 0x0c, 0x00], family: .whoop5).ok)
    }

    func testWhoop5NonSOFRejected() {
        var frame = Self.hex(Self.validWhoop5)
        frame[0] = 0x00
        XCTAssertFalse(verifyFrame(frame, family: .whoop5).ok)
    }

    // MARK: - whoop4 family overload is byte-for-byte back-compatible

    func testWhoop4FamilyOverloadMatchesLegacy() {
        // The existing realtime-data fixture from FramingTests must verify identically through the
        // family-aware overload.
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(verifyFrame(frame, family: .whoop4), verifyFrame(frame))
        XCTAssertTrue(verifyFrame(frame, family: .whoop4).ok)
    }

    // MARK: - CLIENT_HELLO constant

    func testWhoop5ClientHelloBytesAndVerify() {
        let hello = DeviceFamily.whoop5ClientHello
        XCTAssertEqual(hello, Self.hex("aa0108000001e67123019101363e5c8d"))
        XCTAssertEqual(DeviceFamily.whoop5.clientHello, hello)
        XCTAssertNil(DeviceFamily.whoop4.clientHello)
        // The real CLIENT_HELLO must pass whoop5 verification end-to-end.
        let check = verifyFrame(hello, family: .whoop5)
        XCTAssertTrue(check.ok)
        XCTAssertEqual(check.length, 8)   // payload(4) + crc32(4)
    }

    // MARK: - Per-family metadata (no CoreBluetooth)

    func testFamilyMetadata() {
        XCTAssertEqual(DeviceFamily.whoop4.headerCRCKind, .crc8)
        XCTAssertEqual(DeviceFamily.whoop5.headerCRCKind, .crc16Modbus)

        XCTAssertEqual(DeviceFamily.whoop4.serviceUUIDString,
                       "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        XCTAssertEqual(DeviceFamily.whoop5.serviceUUIDString,
                       "fd4b0001-cce1-4033-93ce-002d5875f58a")

        XCTAssertEqual(DeviceFamily.whoop4.characteristicUUIDStrings.count, 4)
        XCTAssertEqual(DeviceFamily.whoop5.characteristicUUIDStrings.count, 5)
        XCTAssertTrue(DeviceFamily.whoop5.characteristicUUIDStrings
            .contains("fd4b0007-cce1-4033-93ce-002d5875f58a"))

        XCTAssertEqual(DeviceFamily.whoop4.commandCharacteristicUUIDString,
                       "61080002-8d6d-82b8-614a-1c8cb0f8dcc6")
        XCTAssertEqual(DeviceFamily.whoop5.commandCharacteristicUUIDString,
                       "fd4b0002-cce1-4033-93ce-002d5875f58a")

        XCTAssertEqual(DeviceFamily.allCases, [.whoop4, .whoop5])
    }

    // MARK: - Puffin packet type names

    func testPuffinTypeNamesAliased() {
        let schema = loadSchema()
        // 38 -> COMMAND_RESPONSE, 56 -> METADATA (not "unknown"/"typeN").
        XCTAssertEqual(canonicalTypeName(38, schema: schema), "COMMAND_RESPONSE")
        XCTAssertEqual(canonicalTypeName(56, schema: schema), "METADATA")
        // Non-puffin types defer to the schema unchanged.
        XCTAssertEqual(canonicalTypeName(40, schema: schema), schema.typeName(40))
        XCTAssertEqual(canonicalTypeName(36, schema: schema), "COMMAND_RESPONSE")
        XCTAssertEqual(PuffinPacketType.puffinCommandResponse, 38)
        XCTAssertEqual(PuffinPacketType.puffinMetadata, 56)
    }

    // MARK: - Family-aware parseFrame

    func testParseWhoop5FrameAliasesPuffinAndParsesEnvelope() {
        // A puffin-metadata (type 56) frame must parse with typeName "METADATA".
        // payload=[56 03 00 ab cd 00 00 00] (padded), crc32 over it.
        let frame = Self.hex("aa010c000001e741380300abcd00000060153281")
        let parsed = parseFrame(frame, family: .whoop5, collectFields: true)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "METADATA")
        XCTAssertEqual(parsed.seq, 3)
        XCTAssertEqual(parsed.crcOK, true)
        // SOF/length/crc16/packet_type envelope fields are present.
        XCTAssertTrue(parsed.fields.contains { $0.name == "crc16" })
        XCTAssertTrue(parsed.fields.contains { $0.name == "packet_type" })
    }

    func testParseWhoop5CommandResponseFrame() {
        let frame = Self.hex(Self.validWhoop5)
        let parsed = parseFrame(frame, family: .whoop5)
        XCTAssertTrue(parsed.ok)
        XCTAssertEqual(parsed.typeName, "COMMAND_RESPONSE")
        XCTAssertEqual(parsed.seq, 7)
        XCTAssertEqual(parsed.crcOK, true)
    }

    func testParseWhoop4FamilyOverloadMatchesLegacy() {
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(parseFrame(frame, family: .whoop4), parseFrame(frame))
    }

    // MARK: - Family-aware Reassembler

    func testReassemblerWhoop5SingleFrame() {
        // validWhoop5 is a complete 20-byte frame: declLength=12 @ [2..4] -> total = 12 + 8 = 20.
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        let out = r.feed(frame)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    func testReassemblerWhoop5SplitAcrossFragments() {
        // A whoop5 frame split mid-way must only emit once both halves have arrived.
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        XCTAssertEqual(r.feed(Array(frame[0..<9])).count, 0)   // incomplete so far
        let out = r.feed(Array(frame[9...]))                   // rest arrives
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    func testReassemblerWhoop5BackToBackFrames() {
        // Two whoop5 frames in one buffer (the 16-byte CLIENT_HELLO then the 20-byte fixture).
        let hello = DeviceFamily.whoop5ClientHello     // declLength=8 -> total 16
        let frame = Self.hex(Self.validWhoop5)          // total 20
        let r = Reassembler(family: .whoop5)
        let out = r.feed(hello + frame)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], hello)
        XCTAssertEqual(out[1], frame)
    }

    func testReassemblerWhoop5DiscardsLeadingGarbage() {
        let frame = Self.hex(Self.validWhoop5)
        let r = Reassembler(family: .whoop5)
        let out = r.feed([0x00, 0xFF, 0x12] + frame)   // junk before the 0xAA SOF
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, frame)
    }

    func testReassemblerWhoop4DefaultUnchanged() {
        // Default family stays WHOOP 4.0: a 28-byte whoop4 frame (length=0x18=24 -> total 28).
        let frame = Self.hex("aa1800ff28020f3de10128663c0000000000000000000000da855212")
        XCTAssertEqual(Reassembler().feed(frame), [frame])
        XCTAssertEqual(Reassembler(family: .whoop4).feed(frame), [frame])
    }
}
