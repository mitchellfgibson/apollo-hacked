import Foundation
import GRDB

// MARK: - Sync-coverage reads (fork-local)
//
// The two reads behind this fork's Settings sync ring. Kept in their own file rather than inside
// `Reads.swift` so they stay obvious — and so pulling upstream again never conflicts on them.
//
// Both count a second as "covered" if EITHER the strap measured it (`hrSample`) or the optical
// estimate filled it (`ppgHrSample`), matching the union `hrBuckets` reads. On WHOOP 5/MG whole
// stretches exist only as the PPG-derived estimate, so counting `hrSample` alone would report a
// fully-drained night as a hole and hold the ring permanently short of full.

public extension WhoopStore {

    /// Seconds the newest persisted HR record lags behind `now` (nil when there is none).
    ///
    /// This is the HONEST "are we caught up" signal for the sync ring: a raw calendar-hour coverage
    /// count wrongly treats every off-wrist hour (shower, gym, charging) as a permanent hole, so it
    /// can never reach 100% however perfectly we sync. What actually matters is whether our newest
    /// data is close to the present — i.e. we've drained everything the strap recorded up to now.
    func secondsBehind(deviceId: String, now: Int) async throws -> Int? {
        try syncRead { db in
            guard let newest = try Int.fetchOne(db, sql: """
                SELECT MAX(ts) FROM (
                    SELECT MAX(ts) AS ts FROM hrSample     WHERE deviceId = ?
                    UNION ALL
                    SELECT MAX(ts) AS ts FROM ppgHrSample  WHERE deviceId = ?
                )
                """, arguments: [deviceId, deviceId])
            else { return nil }
            return max(0, now - newest)
        }
    }

    /// Gap-aware wear-completeness for the sync ring: of the history we SHOULD have (hours the strap
    /// was actually worn), what fraction have we pulled? Returns `(coveredHours, smallHoleHours)`:
    ///   • `coveredHours` — distinct hour-buckets in [from, to] that have HR data,
    ///   • `smallHoleHours` — empty hours sandwiched in a wear session (gaps between consecutive
    ///     covered hours that are LONGER than 1 hour but no longer than `maxWornGapHours`).
    /// A gap longer than `maxWornGapHours` is treated as "strap taken off" (a sleep-length off-wrist
    /// stretch) and NOT counted as missing — you can't be missing data that was never recorded.
    /// Completeness = covered / (covered + smallHoles): 1.0 when every worn hour is drained, and it
    /// only drops for holes INSIDE a wear session (a botched/interrupted sync), which is exactly the
    /// "we still owe you history" signal — off-wrist time never drags it down. `maxWornGapHours`
    /// default 3h comfortably spans real usage gaps (shower + commute) while still catching a genuine
    /// mid-session hole.
    func wearCompleteness(deviceId: String, from: Int, to: Int,
                          maxWornGapHours: Int = 3) async throws -> (covered: Int, smallHoles: Int) {
        try syncRead { db in
            let covered = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT ts / 3600 AS hr FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION
                    SELECT ts / 3600 AS hr FROM ppgHrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                )
                """, arguments: [deviceId, from, to, deviceId, from, to]) ?? 0
            // Sum (gap-1) empty hours for gaps that are >1h and ≤maxWornGapHours between consecutive
            // covered hour-buckets. LAG gives the previous covered hour; a gap of exactly 1 is
            // contiguous (no hole). Everything larger than the cap is off-wrist, excluded.
            let smallHoles = try Int.fetchOne(db, sql: """
                WITH hours AS (
                    SELECT ts / 3600 AS h FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION
                    SELECT ts / 3600 AS h FROM ppgHrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ),
                gaps AS (
                    SELECT h - LAG(h) OVER (ORDER BY h) AS gap FROM hours
                )
                SELECT COALESCE(SUM(gap - 1), 0) FROM gaps WHERE gap > 1 AND gap <= ?
                """, arguments: [deviceId, from, to, deviceId, from, to, maxWornGapHours]) ?? 0
            return (covered, smallHoles)
        }
    }
}
