import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Shared decoder — JSONDecoder is stateless across decodes and was previously allocated once
    /// per event row. Battery events are dense (~every 8 min), so a multi-year read decodes
    /// thousands of rows; reusing one decoder removes that per-row allocation.
    fileprivate static let eventDecoder = JSONDecoder()

    /// Count of DISTINCT hour-buckets that have any HR sample in [from, to] — a cheap coverage
    /// measure for the sync ring ("how much of the strap's stored window have we actually pulled").
    /// Grouping by the integer hour (ts/3600) is index-friendly and avoids a per-row string format.
    public func coveredHours(deviceId: String, from: Int, to: Int) async throws -> Int {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT ts / 3600 AS hr FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    GROUP BY hr
                )
                """, arguments: [deviceId, from, to]) ?? 0
        }
    }

    /// How far behind "now" our newest persisted HR record is, in seconds (nil if we have none).
    /// This is the HONEST "are we caught up" signal for the sync ring: a raw calendar-hour coverage
    /// count wrongly treats every off-wrist hour (shower, gym, charging) as a permanent hole, so it
    /// can never reach 100% however perfectly we sync. What actually matters is whether our newest
    /// data is close to the present — i.e. we've drained everything the strap has recorded up to now.
    /// Small lag (minutes/an hour) = live; a week of lag = genuinely behind. Off-wrist gaps in the
    /// middle don't count against it, because the strap never recorded anything there to pull.
    public func secondsBehind(deviceId: String, now: Int) async throws -> Int? {
        try syncRead { db in
            guard let newest = try Int.fetchOne(db,
                sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
            else { return nil }
            return max(0, now - newest)
        }
    }

    /// Gap-aware wear-completeness for the sync ring: of the history we SHOULD have (hours the strap
    /// was actually worn), what fraction have we pulled? Returns `(coveredHours, smallHoleHours)`:
    ///   • `coveredHours` — distinct hour-buckets in [from, to] that have HR data,
    ///   • `smallHoleHours` — empty hours sandwiched in a wear session (gaps between consecutive
    ///     covered hours that are LONGER than 1 hour but no longer than `maxWornGapHours`).
    /// A gap longer than `maxWornGapHours` is treated as "strap taken off" (sleep-length off-wrist
    /// stretch) and NOT counted as missing — you can't be missing data that was never recorded.
    /// Completeness = covered / (covered + smallHoles): 1.0 when every worn hour is drained, and it
    /// only drops for holes INSIDE a wear session (a botched/interrupted sync), which is exactly the
    /// "we still owe you history" signal — off-wrist time never drags it down. `maxWornGapHours`
    /// default 3h comfortably spans real usage gaps (shower + commute) while still catching a genuine
    /// mid-session hole.
    public func wearCompleteness(deviceId: String, from: Int, to: Int,
                                 maxWornGapHours: Int = 3) async throws -> (covered: Int, smallHoles: Int) {
        try syncRead { db in
            let covered = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT ts / 3600 AS hr FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ? GROUP BY hr
                )
                """, arguments: [deviceId, from, to]) ?? 0
            // Sum (gap-1) empty hours for gaps that are >1h and ≤maxWornGapHours between consecutive
            // covered hour-buckets. LAG gives the previous covered hour; a gap of exactly 1 is
            // contiguous (no hole). Everything larger than the cap is off-wrist, excluded.
            let smallHoles = try Int.fetchOne(db, sql: """
                WITH hours AS (
                    SELECT DISTINCT ts / 3600 AS h FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ),
                gaps AS (
                    SELECT h - LAG(h) OVER (ORDER BY h) AS gap FROM hours
                )
                SELECT COALESCE(SUM(gap - 1), 0) FROM gaps WHERE gap > 1 AND gap <= ?
                """, arguments: [deviceId, from, to, maxWornGapHours]) ?? 0
            return (covered, smallHoles)
        }
    }

    public func hrSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [HRSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        }
    }

    public func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RRInterval] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, rrMs FROM rrInterval
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, rrMs ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RRInterval(ts: $0["ts"], rrMs: $0["rrMs"]) }
        }
    }

    public func events(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [WhoopEvent] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, kind, payloadJSON FROM event
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC, kind ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { row in
                    let json: String = row["payloadJSON"]
                    let payload = (try? WhoopStore.eventDecoder.decode(
                        [String: ParsedValue].self,
                        from: Data(json.utf8))) ?? [:]
                    return WhoopEvent(ts: row["ts"], kind: row["kind"], payload: payload)
                }
        }
    }

    public func batterySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [BatterySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, soc, mv FROM battery
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { BatterySample(ts: $0["ts"], soc: $0["soc"], mv: $0["mv"]) }
        }
    }

    public func spo2Samples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SpO2Sample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, red, ir FROM spo2Sample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SpO2Sample(ts: $0["ts"], red: $0["red"], ir: $0["ir"]) }
        }
    }

    public func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SkinTempSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM skinTempSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { SkinTempSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func respSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RespSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, raw FROM respSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { RespSample(ts: $0["ts"], raw: $0["raw"]) }
        }
    }

    public func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [GravitySample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, x, y, z FROM gravitySample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts ASC LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { GravitySample(ts: $0["ts"], x: $0["x"], y: $0["y"], z: $0["z"]) }
        }
    }

    /// Max HR sample timestamp for a device, or nil if there are none. The biometric "data frontier"
    /// used by the stuck-strap watchdog (advances iff the strap is actually logging + offloading).
    public func latestHRSampleTs(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db,
                sql: "SELECT MAX(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    /// Min HR sample timestamp for a device (our OLDEST record), or nil if none. Compared to the
    /// strap's oldest reported record (GET_DATA_RANGE) to decide if older history remains to pull.
    public func oldestHRSampleTs(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db,
                sql: "SELECT MIN(ts) FROM hrSample WHERE deviceId = ?", arguments: [deviceId])
        }
    }

    /// Aggregate storage footprint: total decoded rows, raw batch count, total raw byteSize.
    public func storageStats() async throws -> (decodedRows: Int, rawBatches: Int, rawBytes: Int) {
        try syncRead { db in
            let hr   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let ev   = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let bat  = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skin = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let grav = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            let batches = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch") ?? 0
            let bytes   = try Int.fetchOne(db,
                sql: "SELECT COALESCE(SUM(byteSize), 0) FROM rawBatch") ?? 0
            return (hr + rr + ev + bat + spo2 + skin + resp + grav, batches, bytes)
        }
    }
}
