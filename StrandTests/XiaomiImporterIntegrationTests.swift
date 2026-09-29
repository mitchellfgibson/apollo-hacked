import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// End-to-end check of the app-side glue: parse a Mi Fitness export, write it into an
/// in-memory WhoopStore under the `xiaomi-band` source, and read the rows back. Runs
/// against the user's real export when `XIAOMI_REAL_DB` is set; otherwise skips.
final class XiaomiImporterIntegrationTests: XCTestCase {

    func testRealExportRoundTripsIntoStore() async throws {
        guard let path = ProcessInfo.processInfo.environment["XIAOMI_REAL_DB"] else {
            throw XCTSkip("Set XIAOMI_REAL_DB to verify the full import pipeline")
        }
        let store = try await WhoopStore.inMemory()
        let summary = try await XiaomiImporter.importExport(
            url: URL(fileURLWithPath: path), into: store)
        XCTAssertEqual(summary.sourceKind, .xiaomiBand)
        XCTAssertGreaterThan(summary.recordCount, 0)

        let id = XiaomiImporter.deviceId

        // Daily metrics landed and carry resting HR.
        let days = try await store.dailyMetrics(deviceId: id, from: "0000-00-00", to: "9999-99-99")
        XCTAssertGreaterThan(days.count, 100)
        XCTAssertTrue(days.contains { $0.restingHr != nil }, "some days should have resting HR")
        XCTAssertTrue(days.contains { ($0.totalSleepMin ?? 0) > 0 }, "some days should have sleep")

        // Sleep sessions landed with a valid hypnogram JSON.
        let sleeps = try await store.sleepSessions(deviceId: id, from: 0, to: Int(Date.distantFuture.timeIntervalSince1970), limit: 10_000)
        XCTAssertGreaterThan(sleeps.count, 0)
        let withStages = try XCTUnwrap(sleeps.first { ($0.stagesJSON?.count ?? 0) > 2 })
        let data = try XCTUnwrap(withStages.stagesJSON?.data(using: .utf8))
        let segs = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertFalse(segs.isEmpty)
        let stages = Set(segs.compactMap { $0["stage"] as? String })
        XCTAssertTrue(stages.isSubset(of: ["wake", "light", "deep", "rem"]), "unexpected stage label in \(stages)")

        // Generic metric series is queryable by key.
        let keys = try await store.metricKeys(deviceId: id)
        XCTAssertTrue(keys.contains("steps"))
        XCTAssertTrue(keys.contains("sleep_score"))

        print("xiaomi import → \(days.count) days, \(sleeps.count) sleeps, keys: \(keys.sorted().joined(separator: ","))")
    }
}
