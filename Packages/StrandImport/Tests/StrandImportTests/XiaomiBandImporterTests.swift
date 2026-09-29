import XCTest
import Foundation
import GRDB
@testable import StrandImport

final class XiaomiBandImporterTests: XCTestCase {

    // MARK: - Synthetic Mi Fitness DB

    /// Build a minimal Mi Fitness-shaped SQLite file (the columns the importer reads:
    /// `sid, key, time, value, zone_offset, time_zero, deleted`) and return its path.
    private func makeMiFitnessDB(_ rows: [(table: String, time: Int, zone: Int, value: [String: Any], deleted: Int)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("8281032873.db")
        let dbq = try DatabaseQueue(path: url.path)
        let tables = Set(rows.map(\.table)).union(["steps"])
        try dbq.write { db in
            for t in tables {
                try db.execute(sql: """
                    CREATE TABLE "\(t)" (sid TEXT, key TEXT, time INTEGER, value TEXT,
                        zone_offset INTEGER, time_zero INTEGER, deleted INTEGER DEFAULT 0)
                    """)
            }
            for r in rows {
                let json = String(data: try JSONSerialization.data(withJSONObject: r.value), encoding: .utf8)!
                try db.execute(sql: """
                    INSERT INTO "\(r.table)" (sid, key, time, value, zone_offset, time_zero, deleted)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: ["default", r.table, r.time, json, r.zone, r.time, r.deleted])
            }
        }
        return url
    }

    private let day0 = 1742601600   // 2025-03-22T00:00:00Z
    private let day1 = 1742688000   // 2025-03-23T00:00:00Z

    func testDayRollupMapping() throws {
        let url = try makeMiFitnessDB([
            ("steps_day", day0, 0, ["steps": 8421, "distance": 6123, "goal": 6000], 0),
            ("calories_day", day0, 0, ["calories": 312, "goal": 500], 0),
            ("heart_rate_day", day0, 0, ["avg_hr": 71, "min_hr": 55, "max_hr": 142, "avg_rhr": 58], 0),
            ("stress_day", day0, 0, ["avg_stress": 34], 0),
            ("spo2_day", day0, 0, ["avg_spo2": 97], 0),
            ("valid_stand_day", day0, 0, ["count": 9], 0),
            // A different day, with a 0 resting HR that must collapse to nil.
            ("heart_rate_day", day1, 0, ["avg_hr": 68, "avg_rhr": 0, "min_hr": 50, "max_hr": 120], 0),
            // A deleted row must be ignored entirely.
            ("steps_day", day1, 0, ["steps": 99999], 1),
        ])

        let result = try XiaomiBandImporter().import(from: url)
        XCTAssertEqual(result.summary.sourceKind, .xiaomiBand)

        let d0 = try XCTUnwrap(result.days.first { $0.day == "2025-03-22" })
        XCTAssertEqual(d0.steps, 8421)
        XCTAssertEqual(d0.distanceM, 6123)
        XCTAssertEqual(d0.activeKcal, 312)
        XCTAssertEqual(d0.restingHr, 58)
        XCTAssertEqual(d0.avgHr, 71)
        XCTAssertEqual(d0.maxHr, 142)
        XCTAssertEqual(d0.avgStress, 34)
        XCTAssertEqual(d0.avgSpo2, 97)
        XCTAssertEqual(d0.standCount, 9)

        let d1 = try XCTUnwrap(result.days.first { $0.day == "2025-03-23" })
        XCTAssertNil(d1.restingHr, "avg_rhr of 0 means 'not measured' → nil")
        XCTAssertNil(d1.steps, "deleted steps_day row must not contribute")
    }

    func testSleepSessionAndHypnogram() throws {
        let bed = 1752718320, wake = 1752740880
        let value: [String: Any] = [
            "bedtime": bed,
            "out_bed_timestamp": wake,
            "avg_hr": 60, "min_hr": 53, "max_hr": 82,
            "sleep_deep_duration": 123, "sleep_light_duration": 159,
            "sleep_rem_duration": 85, "sleep_awake_duration": 9, "awake_count": 3,
            "items": [
                ["start_time": bed, "end_time": bed + 1860, "state": 3],          // deep
                ["start_time": bed + 1860, "end_time": bed + 2280, "state": 2],    // light
                ["start_time": bed + 2280, "end_time": bed + 2520, "state": 4],    // rem
                ["start_time": bed + 2520, "end_time": bed + 2640, "state": 1],    // awake
                ["start_time": 0, "end_time": 0, "state": 2],                       // junk → skipped
            ],
        ]
        let url = try makeMiFitnessDB([("sleep", wake, 3600, value, 0)])

        let result = try XiaomiBandImporter().import(from: url)
        XCTAssertEqual(result.sleeps.count, 1)
        let s = try XCTUnwrap(result.sleeps.first)
        XCTAssertEqual(Int(s.bedtime.timeIntervalSince1970), bed)
        XCTAssertEqual(Int(s.wakeTime.timeIntervalSince1970), wake)
        XCTAssertEqual(s.deepMin, 123)
        XCTAssertEqual(s.avgHr, 60)
        XCTAssertEqual(s.awakeCount, 3)
        XCTAssertEqual(s.stages.count, 4, "the zero-length junk item must be dropped")
        XCTAssertEqual(s.stages.map(\.stage), [.deep, .light, .rem, .awake])
        XCTAssertEqual(Int(s.stages[0].end.timeIntervalSince1970), bed + 1860)
    }

    func testBareDBAndEmptyGuard() throws {
        // Empty (no health rows) → emptyExport.
        let empty = try makeMiFitnessDB([])
        XCTAssertThrowsError(try XiaomiBandImporter().import(from: empty))

        // Detection: a bare *.db routes to .xiaomiBand.
        let url = try makeMiFitnessDB([("steps_day", day0, 0, ["steps": 10], 0)])
        XCTAssertEqual(try ImportCoordinator().detectKind(of: url), .xiaomiBand)
    }

    // MARK: - Real export (opt-in, ground truth)

    /// Runs against the user's real Mi Band 10 export when `XIAOMI_REAL_DB` points at
    /// the `<user_id>.db` (or the sandbox folder). Skipped in normal CI.
    func testRealExportIfAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["XIAOMI_REAL_DB"] else {
            throw XCTSkip("Set XIAOMI_REAL_DB to verify against the real export")
        }
        let result = try XiaomiBandImporter().import(from: URL(fileURLWithPath: path))
        print("== Real Mi Band export ==")
        print("days: \(result.days.count)  sleeps: \(result.sleeps.count)")
        print("range: \(result.summary.earliest.map(String.init(describing:)) ?? "?") … \(result.summary.latest.map(String.init(describing:)) ?? "?")")
        if let withRhr = result.days.first(where: { $0.restingHr != nil }) {
            print("sample day \(withRhr.day): steps=\(withRhr.steps ?? -1) rhr=\(withRhr.restingHr ?? -1) sleepMin=\(withRhr.totalSleepMin ?? -1) score=\(withRhr.sleepScore ?? -1)")
        }
        if let s = result.sleeps.first(where: { !$0.stages.isEmpty }) {
            print("sample sleep: \(s.stages.count) stages, deep=\(s.deepMin ?? -1) avgHr=\(s.avgHr ?? -1)")
        }
        XCTAssertGreaterThan(result.days.count, 0)
        XCTAssertGreaterThan(result.sleeps.count, 0)
        XCTAssertTrue(result.sleeps.contains { !$0.stages.isEmpty }, "real sleep should carry a hypnogram")
    }
}
