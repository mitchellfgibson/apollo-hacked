import XCTest
@testable import WhoopProtocol

/// v26 PPG extraction: the WHOOP 5 decoder surfaces `ppg_waveform` in `parsed`; the historical
/// extractor must turn it into a `PPGWaveformSample` row instead of dropping it on the floor.
final class PPGExtractTests: XCTestCase {
    private func histFrame(parsed: [String: ParsedValue]) -> ParsedFrame {
        ParsedFrame(ok: true, typeName: "HISTORICAL_DATA", seq: nil, cmdName: nil,
                    crcOK: true, lenBytes: 0, rawHex: "", fields: [], parsed: parsed)
    }

    func testV26WaveformIsExtracted() {
        let samples = (0..<24).map { $0 * 100 - 1200 }   // i16-range dummy waveform
        let f = histFrame(parsed: ["unix": .int(1_750_000_000),
                                   "ppg_waveform": .intArray(samples)])
        let out = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertEqual(out.ppg.count, 1)
        XCTAssertEqual(out.ppg[0].ts, 1_750_000_000)
        XCTAssertEqual(out.ppg[0].samples, samples)
        XCTAssertEqual(out.ppg[0].unit, "raw_adc")
    }

    func testV18FrameYieldsNoPPG() {
        // v18 summary frames carry no `ppg_waveform` key — extraction is a no-op for them.
        let f = histFrame(parsed: ["unix": .int(1_750_000_000), "heart_rate": .int(62)])
        let out = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertTrue(out.ppg.isEmpty)
        XCTAssertEqual(out.hr.count, 1)
    }

    func testEmptyWaveformIsSkipped() {
        let f = histFrame(parsed: ["unix": .int(1_750_000_000), "ppg_waveform": .intArray([])])
        let out = extractHistoricalStreams([f], deviceClockRef: 0, wallClockRef: 0)
        XCTAssertTrue(out.ppg.isEmpty)
    }

    func testStreamsDecodesWithoutPPGKey() throws {
        // Backward compat: fixtures encoded before the ppg field existed must still decode.
        let json = #"{"hr":[{"ts":1,"bpm":60,"unit":"bpm"}]}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(Streams.self, from: json)
        XCTAssertEqual(s.hr, [HRSample(ts: 1, bpm: 60)])
        XCTAssertTrue(s.ppg.isEmpty)
    }

    func testStreamsPPGRoundTripsThroughCodable() throws {
        let s = Streams(ppg: [PPGWaveformSample(ts: 5, samples: [-32768, 0, 32767])])
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Streams.self, from: data)
        XCTAssertEqual(back.ppg, s.ppg)
    }
}
