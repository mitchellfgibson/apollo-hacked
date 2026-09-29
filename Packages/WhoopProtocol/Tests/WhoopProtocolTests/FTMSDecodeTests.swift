import XCTest
@testable import WhoopProtocol

/// Spec-deterministic FTMS field-decode contract. Fixtures are built BYTE-BY-BYTE from the Bluetooth
/// SIG Fitness Machine Service field tables (not a real capture), so each asserts the exact flag→field
/// mapping and the fixed-point→unit scaling for the fields NOOP surfaces (speed, cadence, power,
/// distance, total energy, heart rate, elapsed time). Pure decode → headless `swift test`.
final class FTMSDecodeTests: XCTestCase {

    private func bytes(_ v: [Int]) -> [UInt8] { v.map { UInt8($0 & 0xFF) } }
    /// Little-endian u16 → [lo, hi].
    private func le16(_ v: Int) -> [Int] { [v & 0xFF, (v >> 8) & 0xFF] }
    /// Little-endian u24 → [lo, mid, hi].
    private func le24(_ v: Int) -> [Int] { [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF] }

    // MARK: - Treadmill (0x2ACD)

    func testTreadmillSpeedDistanceEnergyHRElapsed() {
        // flags: speed present (bit0=0), Total Distance (bit2), Total Energy (bit7),
        // Heart Rate (bit8), Elapsed Time (bit10) → 0x0584.
        let flags = 0x0004 | 0x0080 | 0x0100 | 0x0400      // 0x0584
        var p: [Int] = le16(flags)
        p += le16(853)                                     // Inst. Speed 8.53 km/h (×0.01)
        p += le24(1250)                                    // Total Distance 1250 m
        p += le16(42)                                      // Total Energy 42 kcal
        p += le16(300)                                     // Energy/hour (skipped)
        p += [5]                                           // Energy/min (skipped)
        p += [131]                                         // Heart Rate 131 bpm
        p += le16(615)                                     // Elapsed Time 615 s

        let r = FTMSDecode.treadmill(bytes(p))!
        XCTAssertEqual(r.kind, .treadmill)
        XCTAssertEqual(r.speedKmh!, 8.53, accuracy: 0.0001)
        XCTAssertEqual(r.distanceM, 1250)
        XCTAssertEqual(r.totalEnergyKcal, 42)
        XCTAssertEqual(r.heartRate, 131)
        XCTAssertEqual(r.elapsedTimeSec, 615)
        XCTAssertNil(r.powerWatts)
        XCTAssertNil(r.cadence)
    }

    func testTreadmillMoreDataBitOmitsSpeed() {
        // bit0 (More Data) SET → Instantaneous Speed is ABSENT. Only Heart Rate (bit8) follows.
        let flags = 0x0001 | 0x0100
        let p = le16(flags) + [99]
        let r = FTMSDecode.treadmill(bytes(p))!
        XCTAssertNil(r.speedKmh)            // proves the speed bytes weren't consumed
        XCTAssertEqual(r.heartRate, 99)
    }

    func testTreadmillInclinationAndElevationAreSkippedNotMisread() {
        // More Data (bit0) set → speed ABSENT; Inclination+Ramp (bit3, 4 bytes) and Elevation (bit4, 4
        // bytes) precede Heart Rate (bit8). If they weren't skipped by the right width, HR would misdecode.
        let flags = 0x0001 | 0x0008 | 0x0010 | 0x0100
        var p = le16(flags)
        p += le16(0x1234) + le16(0x5678)   // inclination + ramp (skipped)
        p += le16(0x0010) + le16(0x0000)   // pos + neg elevation (skipped)
        p += [77]                          // Heart Rate
        let r = FTMSDecode.treadmill(bytes(p))!
        XCTAssertNil(r.speedKmh)
        XCTAssertEqual(r.heartRate, 77)
    }

    // MARK: - Indoor Bike (0x2AD2)

    func testIndoorBikeSpeedCadencePowerEnergyHR() {
        // flags: speed present, Inst. Cadence (bit2), Inst. Power (bit6), Total Energy (bit8),
        // Heart Rate (bit9) → 0x0344.
        let flags = 0x0004 | 0x0040 | 0x0100 | 0x0200
        var p = le16(flags)
        p += le16(3000)                    // speed 30.00 km/h
        p += le16(180)                     // cadence raw 180 → 90.0 rpm (×0.5)
        p += le16(245)                     // power 245 W
        p += le16(73)                      // total energy 73 kcal
        p += le16(600) + [10]              // energy/hour + energy/min (skipped)
        p += [142]                         // heart rate
        let r = FTMSDecode.indoorBike(bytes(p))!
        XCTAssertEqual(r.speedKmh!, 30.0, accuracy: 0.0001)
        XCTAssertEqual(r.cadence!, 90.0, accuracy: 0.0001)
        XCTAssertEqual(r.powerWatts, 245)
        XCTAssertEqual(r.totalEnergyKcal, 73)
        XCTAssertEqual(r.heartRate, 142)
    }

    func testIndoorBikeNegativePowerIsSigned() {
        // More Data (bit0) set → speed absent; Inst. Power (bit6) only; sint16 0xFFFF = -1 W (coasting).
        let flags = 0x0001 | 0x0040
        let p = le16(flags) + le16(0xFFFF)
        let r = FTMSDecode.indoorBike(bytes(p))!
        XCTAssertNil(r.speedKmh)
        XCTAssertEqual(r.powerWatts, -1)
    }

    // MARK: - Rower (0x2AD1)

    func testRowerStrokeRateDistancePowerEnergyHR() {
        // flags: stroke present (bit0=0), Total Distance (bit2), Inst. Power (bit5),
        // Total Energy (bit8), Heart Rate (bit9) → 0x0324.
        let flags = 0x0004 | 0x0020 | 0x0100 | 0x0200
        var p = le16(flags)
        p += [60]                          // stroke rate raw 60 → 30.0 /min (×0.5)
        p += le16(412)                     // stroke count (skipped)
        p += le24(503)                     // total distance 503 m
        p += le16(160)                     // inst power 160 W
        p += le16(58)                      // total energy 58 kcal
        p += le16(420) + [7]               // energy/hour + /min (skipped)
        p += [128]                         // heart rate
        let r = FTMSDecode.rower(bytes(p))!
        XCTAssertEqual(r.cadence!, 30.0, accuracy: 0.0001)
        XCTAssertEqual(r.distanceM, 503)
        XCTAssertEqual(r.powerWatts, 160)
        XCTAssertEqual(r.totalEnergyKcal, 58)
        XCTAssertEqual(r.heartRate, 128)
    }

    func testRowerMoreDataBitOmitsStroke() {
        // bit0 SET → Stroke Rate + Stroke Count ABSENT. Total Distance (bit2) follows directly.
        let flags = 0x0001 | 0x0004
        let p = le16(flags) + le24(1000)
        let r = FTMSDecode.rower(bytes(p))!
        XCTAssertNil(r.cadence)
        XCTAssertEqual(r.distanceM, 1000)
    }

    // MARK: - Cross Trainer (0x2ACE) — 24-bit flags

    func testCrossTrainerStepRateDistancePowerHR() {
        // 24-bit flags: speed present (bit0=0), Total Distance (bit2), Step Count (bit3),
        // Inst. Power (bit8), Heart Rate (bit11) → 0x00090C.
        let flags = 0x000004 | 0x000008 | 0x000100 | 0x000800
        var p = le16(flags & 0xFFFF) + [(flags >> 16) & 0xFF]
        p += le16(450)                     // speed 4.50 km/h
        p += le24(880)                     // total distance 880 m
        p += le16(56) + le16(54)           // step/min 56 (cadence) + avg step rate (skipped)
        p += le16(112)                     // inst power 112 W
        p += [120]                         // heart rate
        let r = FTMSDecode.crossTrainer(bytes(p))!
        XCTAssertEqual(r.kind, .crossTrainer)
        XCTAssertEqual(r.speedKmh!, 4.5, accuracy: 0.0001)
        XCTAssertEqual(r.distanceM, 880)
        XCTAssertEqual(r.cadence!, 56.0, accuracy: 0.0001)
        XCTAssertEqual(r.powerWatts, 112)
        XCTAssertEqual(r.heartRate, 120)
    }

    // MARK: - Robustness over UNTRUSTED / malformed input

    func testEmptyAndShortBuffersNeverCrash() {
        XCTAssertNil(FTMSDecode.treadmill([]))
        XCTAssertNil(FTMSDecode.indoorBike([0x04]))     // 1 byte: flags need 2 → nil
        XCTAssertNil(FTMSDecode.crossTrainer([0x00, 0x00]))  // needs 3 flag bytes
        // flags=0x0000 → speed present (bit0 clear) but only ONE of its two bytes follows → the half
        // field must NOT be consumed (no over-read), decode what fit, no crash.
        let truncated = FTMSDecode.indoorBike([0x00, 0x00, 0xB8])
        XCTAssertNotNil(truncated)
        XCTAssertNil(truncated!.speedKmh)               // the half speed field was not consumed
    }

    func testHugeBufferIsBounded() {
        // A pathological oversize packet (zip-bomb-style padding) must decode only the declared fields
        // and ignore the trailing junk — never loop over the tail. More Data (bit0) set → speed absent,
        // so HR (bit8) is the only declared field; everything after it is ignored.
        var p = le16(0x0001 | 0x0100) + [88]            // More-Data + HR flag, HR=88
        p += Array(repeating: 0xAB, count: 5000)        // 5 KB of junk after the declared field
        let r = FTMSDecode.treadmill(bytes(p))!
        XCTAssertEqual(r.heartRate, 88)
    }

    func testDecodeByUUIDDispatch() {
        // More Data (bit0) + Heart Rate so the single declared field is the HR byte (no speed to consume).
        XCTAssertEqual(FTMSDecode.decode(uuid16: "2acd", bytes(le16(0x0101) + [70]))?.kind, .treadmill)
        XCTAssertEqual(FTMSDecode.decode(uuid16: "2AD2", bytes(le16(0x0201) + [70]))?.kind, .indoorBike)
        XCTAssertNil(FTMSDecode.decode(uuid16: "1234", [0x00, 0x00]))
    }

    // MARK: - Battery (0x2A19)

    func testBatteryPercentParse() {
        XCTAssertEqual(StandardBattery.parse([72]), 72)
        XCTAssertEqual(StandardBattery.parse([0]), 0)
        XCTAssertEqual(StandardBattery.parse([100]), 100)
    }

    func testBatteryClampsAbove100AndRejectsEmpty() {
        XCTAssertEqual(StandardBattery.parse([200]), 100)   // misbehaving device clamped
        XCTAssertNil(StandardBattery.parse([]))             // empty → nil
    }
}
