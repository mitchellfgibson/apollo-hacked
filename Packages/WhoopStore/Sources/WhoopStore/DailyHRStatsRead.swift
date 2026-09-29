import Foundation
import GRDB

/// Per-local-day heart-rate aggregate for the export ("HR range"). `count` doubles as the day's
/// coverage flag: a low sample count marks a partial day worth filtering out in analysis.
public struct DailyHRStats: Equatable, Sendable {
    public let day: String       // YYYY-MM-DD, local calendar
    public let min: Int
    public let max: Int
    public let avg: Double
    public let count: Int
    public init(day: String, min: Int, max: Int, avg: Double, count: Int) {
        self.day = day; self.min = min; self.max = max; self.avg = avg; self.count = count
    }
}

public extension WhoopStore {

    /// Per-local-day HR aggregate (min / max / mean bpm + sample count) for the Google-Sheet export.
    /// Bucketed by the wearer's LOCAL calendar day so it lines up with the computed dailyMetric rows.
    ///
    /// Reads the SAME measured+derived union `hrBuckets` uses: every `hrSample` row, plus a
    /// `ppgHrSample` row only for a second the strap never measured (anti-join), so a beat is never
    /// counted twice. That matters on WHOOP 5/MG, where long stretches have only the optical
    /// estimate — restricting this to `hrSample` would under-report the day's true range and
    /// under-count coverage.
    func dailyHRStats(deviceId: String, fromDay: String, toDay: String) async throws -> [DailyHRStats] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT date(ts, 'unixepoch', 'localtime') AS day,
                       -- ppgHrSample.bpm is REAL (a float estimate) while hrSample.bpm is INTEGER,
                       -- so the union's min/max come back as floats. Cast so the decoded row matches
                       -- DailyHRStats' Int fields instead of relying on a lossy implicit coercion.
                       CAST(MIN(bpm) AS INTEGER) AS lo,
                       CAST(MAX(bpm) AS INTEGER) AS hi,
                       AVG(bpm) AS mean, COUNT(*) AS n
                FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND bpm > 0
                    UNION ALL
                    SELECT p.ts, p.bpm FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.bpm > 0
                      AND NOT EXISTS (
                        SELECT 1 FROM hrSample h
                        WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                )
                GROUP BY day
                HAVING day >= ? AND day <= ?
                ORDER BY day ASC
                """, arguments: [deviceId, deviceId, fromDay, toDay])
                .map { DailyHRStats(day: $0["day"], min: $0["lo"], max: $0["hi"],
                                    avg: $0["mean"], count: $0["n"]) }
        }
    }
}
