import XCTest
@testable import WhoopProtocol

/// WHOOP 4.0 **v25** historical layout (issue #30). v25 is the firmware layout some 4.0 straps emit
/// that NOOP couldn't decode — "no motion data, so sleep can't be computed." These are three REAL v25
/// records captured on app v1.92+ (faklei), where the strap log dumps the full 84-byte record. The
/// layout was reverse-engineered from 45 such records: `unix` @11 (u32 LE) and the DSP gravity vector
/// at @73/75/77 as 3×i16 LE / 16384 (|gravity| ≈ 1 g). HR is not stored per-second in v25 (PPG-derived),
/// so the record yields motion + timestamp — which is what the sleep stager needs.
final class Whoop4HistoricalV25Tests: XCTestCase {

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    // Real v25 records (faklei, App 1.92, 2026-06-11), 84 bytes each.
    private lazy var records = [
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716",
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf",
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9",
    ].map { bytes($0) }

    func testV25DecodesUnixAndGravity() {
        for rec in records {
            let p = parseFrame(rec, family: .whoop4)
            XCTAssertTrue(p.ok)
            XCTAssertEqual(p.parsed["hist_version"]?.intValue, 25)
            // unix: real seconds on 2026-06-11, incrementing 1 Hz across the three.
            let unix = p.parsed["unix"]?.intValue
            XCTAssertNotNil(unix)
            XCTAssertGreaterThan(unix ?? 0, 1_781_000_000)
            // gravity: a real DSP orientation vector ≈ 1 g.
            let gx = p.parsed["gravity_x"]?.doubleValue
            XCTAssertNotNil(gx, "v25 must decode gravity (the sleep-staging input)")
            let gy = p.parsed["gravity_y"]?.doubleValue ?? 0
            let gz = p.parsed["gravity_z"]?.doubleValue ?? 0
            let mag = ((gx ?? 0) * (gx ?? 0) + gy * gy + gz * gz).squareRoot()
            XCTAssertTrue((0.8...1.2).contains(mag), "|gravity| should be ~1 g, got \(mag)")
        }
        // ts strictly increments (1 Hz).
        let ts = records.map { parseFrame($0, family: .whoop4).parsed["unix"]?.intValue ?? 0 }
        XCTAssertEqual(ts, [ts[0], ts[0] + 1, ts[0] + 2])
    }

    /// A v25 record carries real motion, so it must NOT be classified as an undecodable/rejected
    /// record any more (which would archive + skip it). Before #30's fix these were all rejected.
    func testV25NotRejected() {
        XCTAssertTrue(rejectedHistoricalRecords(records, family: .whoop4).isEmpty,
                      "v25 records carry gravity and must no longer be treated as undecodable")
    }

    /// End to end: the parsed v25 frames produce GravitySample rows the sleep stager consumes.
    func testV25ProducesGravityStream() {
        let parsed = records.map { parseFrame($0, family: .whoop4) }
        let ref = parsed[0].parsed["unix"]?.intValue ?? 0
        let streams = extractHistoricalStreams(parsed, deviceClockRef: ref, wallClockRef: ref)
        XCTAssertEqual(streams.gravity.count, records.count, "every v25 record should yield a gravity sample")
    }
}
