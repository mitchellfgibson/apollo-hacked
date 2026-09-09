import XCTest
import WhoopProtocol
@testable import WhoopStore

/// v10: persistence for the WHOOP 5 v26 24 Hz PPG waveform stream
/// (one row per second, 24 LE-i16 samples packed into a blob).
final class PPGWaveformTests: XCTestCase {
    private func ppgStreams() -> Streams {
        Streams(ppg: [
            PPGWaveformSample(ts: 1700000000, samples: Array(repeating: -100, count: 24)),
            PPGWaveformSample(ts: 1700000001, samples: (0..<24).map { $0 * 1000 - 12000 }),
        ])
    }

    // MARK: - v10 migration

    func testV10CreatesPPGTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("ppgWaveform"))
    }

    func testV10PrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("ppgWaveform")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    // MARK: - insert / read

    func testInsertReturnsPPGCounts() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let n = try await store.insert(ppgStreams(), deviceId: "dev1")
        XCTAssertEqual(n.ppg, 2)
    }

    func testInsertPPGIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(ppgStreams(), deviceId: "dev1")
        let second = try await store.insert(ppgStreams(), deviceId: "dev1")
        XCTAssertEqual(second.ppg, 0)
    }

    func testReadRoundTripsSamplesExactly() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        _ = try await store.insert(ppgStreams(), deviceId: "dev1")
        let rows = try await store.ppgWaveforms(deviceId: "dev1", from: 0, to: Int.max, limit: 10)
        XCTAssertEqual(rows, ppgStreams().ppg)
    }

    func testPackUnpackHandlesI16Extremes() {
        let samples = [-32768, -1, 0, 1, 32767]
        XCTAssertEqual(WhoopStore.unpackPPGSamples(WhoopStore.packPPGSamples(samples)), samples)
    }
}
