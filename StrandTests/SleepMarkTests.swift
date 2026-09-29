import XCTest
import Foundation
import WhoopStore
@testable import Strand

/// #461 Phase 1 — sleep-marks. Covers the pure encode/decode logic and, crucially, the persistence
/// round-trip: write a mark through the SAME `upsertMetricSeries` API the view uses, read the
/// `sleep_mark` series back out, and decode it to the original type.
final class SleepMarkTests: XCTestCase {

    // MARK: - Pure encoding

    func testTypeEncodesToZeroAndOne() {
        XCTAssertEqual(SleepMarkType.bedtime.seriesValue, 0)
        XCTAssertEqual(SleepMarkType.wake.seriesValue, 1)
    }

    func testTypeDecodeIsTolerant() {
        XCTAssertEqual(SleepMarkType.from(seriesValue: 0), .bedtime)
        XCTAssertEqual(SleepMarkType.from(seriesValue: 1), .wake)
        // Float drift rounds to the nearest valid case; out-of-range clamps to bedtime.
        XCTAssertEqual(SleepMarkType.from(seriesValue: 0.999), .wake)
        XCTAssertEqual(SleepMarkType.from(seriesValue: 0.001), .bedtime)
        XCTAssertEqual(SleepMarkType.from(seriesValue: 7), .bedtime)
    }

    func testMetricPointCarriesKeyDayAndValue() {
        // 2024-03-09 14:30:00 UTC → tsMs. dayKey is LOCAL, so just assert the key/value shape and
        // that the day round-trips through the same formatter (timezone-agnostic check below).
        let mark = SleepMark(type: .wake, tsMs: 1_710_000_000_000)
        let point = mark.metricPoint
        XCTAssertEqual(point.key, "sleep_mark")
        XCTAssertEqual(point.value, 1)
        XCTAssertEqual(point.day, mark.dayKey)
    }

    func testLogLineIsHumanReadableAndTyped() {
        let bed = SleepMark(type: .bedtime, tsMs: 1_710_000_000_000).logLine
        let wake = SleepMark(type: .wake, tsMs: 1_710_000_000_000).logLine
        XCTAssertTrue(bed.hasPrefix("Sleep mark · bedtime"), bed)
        XCTAssertTrue(bed.contains("going to sleep"), bed)
        XCTAssertTrue(wake.hasPrefix("Sleep mark · wake"), wake)
        XCTAssertTrue(wake.contains("awake"), wake)
        XCTAssertTrue(bed.contains("@"), bed)
    }

    // MARK: - Persistence round-trip (write → read the series back)

    func testMarkPersistenceRoundTrip() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "my-whoop"

        // Two marks on the same logical instant base, different days, to prove the series reads back.
        let bedMark = SleepMark(type: .bedtime, tsMs: 1_710_000_000_000)   // some day D
        let wakeMark = SleepMark(type: .wake, tsMs: 1_710_086_400_000)     // D + 1 day

        try await store.upsertMetricSeries([bedMark.metricPoint], deviceId: deviceId)
        try await store.upsertMetricSeries([wakeMark.metricPoint], deviceId: deviceId)

        // The key is discoverable and the series is queryable, exactly as the Sleep screen reads it.
        let keys = try await store.metricKeys(deviceId: deviceId)
        XCTAssertTrue(keys.contains("sleep_mark"), "sleep_mark key should be present, got \(keys)")

        let points = try await store.metricSeries(
            deviceId: deviceId, key: "sleep_mark", from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(points.count, 2, "two distinct days → two rows")

        // Decode each point back to a mark and confirm the type survived the round-trip.
        let decoded = points.compactMap { SleepMark.from(point: $0) }
        XCTAssertEqual(decoded.count, 2)
        let byDay = Dictionary(uniqueKeysWithValues: decoded.map { ($0.dayKey, $0.type) })
        XCTAssertEqual(byDay[bedMark.dayKey], .bedtime)
        XCTAssertEqual(byDay[wakeMark.dayKey], .wake)
    }

    func testSameDayUpsertReplacesValueInPlace() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "my-whoop"

        // Two marks on the SAME calendar day: the natural key (deviceId, day, key) means the second
        // upsert overwrites the first's value — last-wins, one row. (The strap log keeps the full
        // sequence; this asserts the documented Phase-1 store behaviour.)
        let base: Int64 = 1_710_000_000_000
        let first = SleepMark(type: .bedtime, tsMs: base)
        let second = SleepMark(type: .wake, tsMs: base + 60_000)   // 1 min later, same day
        XCTAssertEqual(first.dayKey, second.dayKey, "test fixture must be same-day")

        try await store.upsertMetricSeries([first.metricPoint], deviceId: deviceId)
        try await store.upsertMetricSeries([second.metricPoint], deviceId: deviceId)

        let points = try await store.metricSeries(
            deviceId: deviceId, key: "sleep_mark", from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(points.count, 1, "same day upserts to one row")
        XCTAssertEqual(SleepMark.from(point: points[0])?.type, .wake, "last write wins")
    }
}
