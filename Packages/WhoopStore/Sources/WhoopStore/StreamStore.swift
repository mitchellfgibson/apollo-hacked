import Foundation
import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically — important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here — it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int, ppg: Int, imu: Int) {
        return try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0, ppg = 0, imu = 0
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            if !streams.hr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.hr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm])
                    hr += db.changesCount
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs) DO NOTHING
                    """)
                for r in streams.rr {
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs])
                    rr += db.changesCount
                }
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
            }
            if !streams.spo2.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.spo2 {
                    try stmt.execute(arguments: [deviceId, s.ts, s.red, s.ir])
                    spo2 += db.changesCount
                }
            }
            if !streams.skinTemp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO skinTempSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.skinTemp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    skin += db.changesCount
                }
            }
            if !streams.resp.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO respSample (deviceId, ts, raw) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.resp {
                    try stmt.execute(arguments: [deviceId, s.ts, s.raw])
                    resp += db.changesCount
                }
            }
            if !streams.gravity.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO gravitySample (deviceId, ts, x, y, z) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.gravity {
                    try stmt.execute(arguments: [deviceId, s.ts, s.x, s.y, s.z])
                    grav += db.changesCount
                }
            }
            if !streams.ppg.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgWaveform (deviceId, ts, samples) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppg {
                    try stmt.execute(arguments: [deviceId, s.ts, WhoopStore.packPPGSamples(s.samples)])
                    ppg += db.changesCount
                }
            }
            if !streams.imu.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO imuFeature
                        (deviceId, ts, accelMagMean, accelMagSd, jerkMean, gyroMagMean, activityCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.imu {
                    try stmt.execute(arguments: [deviceId, s.ts, s.accelMagMean, s.accelMagSd,
                                                 s.jerkMean, s.gyroMagMean, s.activityCount])
                    imu += db.changesCount
                }
            }
            return (hr, rr, ev, bat, spo2, skin, resp, grav, ppg, imu)
        }
    }

    /// Pack raw PPG ADC counts into a little-endian i16 blob (2 bytes/sample) for the
    /// `ppgWaveform.samples` column. Values are clamped to i16 range; the v26 decoder only
    /// ever produces i16-range reads, so clamping is a no-op safety net.
    static func packPPGSamples(_ samples: [Int]) -> Data {
        var d = Data(); d.reserveCapacity(samples.count * 2)
        for s in samples {
            let v = Int16(clamping: s)
            d.append(UInt8(truncatingIfNeeded: v))
            d.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return d
    }

    /// Inverse of `packPPGSamples` — odd trailing bytes are ignored.
    static func unpackPPGSamples(_ blob: Data) -> [Int] {
        var out: [Int] = []; out.reserveCapacity(blob.count / 2)
        var i = blob.startIndex
        while i + 1 < blob.endIndex {
            let v = Int16(bitPattern: UInt16(blob[i]) | (UInt16(blob[i + 1]) << 8))
            out.append(Int(v))
            i += 2
        }
        return out
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int, ppg: Int, imu: Int) {
        // Broken into named locals: as a single 10-element tuple literal the type checker times out.
        try syncRead { db in
            func count(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            let hr = try count("hrSample")
            let rr = try count("rrInterval")
            let ev = try count("event")
            let bat = try count("battery")
            let spo2 = try count("spo2Sample")
            let skin = try count("skinTempSample")
            let resp = try count("respSample")
            let grav = try count("gravitySample")
            let ppg = try count("ppgWaveform")
            let imu = try count("imuFeature")
            return (hr, rr, ev, bat, spo2, skin, resp, grav, ppg, imu)
        }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }
}
