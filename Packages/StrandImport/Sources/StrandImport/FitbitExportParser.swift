import Foundation

// MARK: - Fitbit Google-Takeout JSON parser
//
// Google Takeout → Fitbit → JSON. The per-day files this lane reads (documented Takeout / Fitbit
// Web-API shapes; NOOP's own clean parser):
//
//   sleep-YYYY-MM-DD.json          — an array of sleep logs. Each: dateOfSleep, startTime, endTime
//                                    (local ISO, no offset), minutesAsleep, minutesAwake, efficiency,
//                                    timeInBed, levels.summary.{deep,light,rem,wake}.minutes, plus an
//                                    optional levels.data[] hypnogram (dateTime, level, seconds).
//   resting_heart_rate-YYYY-...json — array of { dateTime, value:{ date, value, error } }.
//   steps-YYYY-MM-DD.json          — array of { dateTime, value } (value is a step COUNT string).
//   heart_rate-YYYY-MM-DD.json     — intraday array of { dateTime, value:{ bpm, confidence } }. We do
//                                    NOT fabricate a resting HR from it; resting_heart_rate-*.json is the
//                                    honest source. (Intraday HR is high-volume; we skip it for daily.)
//
// Fitbit local times carry no offset, so we interpret them at UTC and key the day off `dateOfSleep`
// (the wake day), matching how the WHOOP/Apple importers key nights.

enum FitbitExportParser {

    static func parse(_ files: [String: Data]) -> (days: [WearableDailyRow], sleeps: [WearableSleepSession]) {
        var byDay: [String: WearableDailyRow] = [:]
        var sleeps: [WearableSleepSession] = []
        func day(_ key: String) -> WearableDailyRow { byDay[key] ?? WearableDailyRow(day: key) }

        for (name, data) in files {
            let base = (name as NSString).lastPathComponent
            if base.hasPrefix("sleep") || base.contains("sleep") {
                for log in WearableJSON.array(data)?.compactMap({ $0 as? [String: Any] }) ?? [] {
                    guard let session = sleepSession(log) else { continue }
                    sleeps.append(session)
                    let key = WearableJSON.str(log, "dateOfSleep") ?? WearableExportImporter.dayString(session.end)
                    var row = day(key)
                    row.totalSleepMin = row.totalSleepMin ?? session.totalSleepMin
                    row.deepMin = row.deepMin ?? session.deepMin
                    row.lightMin = row.lightMin ?? session.lightMin
                    row.remMin = row.remMin ?? session.remMin
                    row.awakeMin = row.awakeMin ?? session.awakeMin
                    row.efficiencyPct = row.efficiencyPct ?? session.efficiencyPct
                    byDay[key] = row
                }
            } else if base.hasPrefix("resting_heart_rate") || base.contains("resting_heart_rate") {
                for e in WearableJSON.array(data)?.compactMap({ $0 as? [String: Any] }) ?? [] {
                    guard let key = dayKey(WearableJSON.str(e, "dateTime")) else { continue }
                    // resting_heart_rate value is nested: { value: { date, value, error } }.
                    let rhr: Int?
                    if let v = e["value"] as? [String: Any] { rhr = WearableJSON.posInt(v, "value") }
                    else { rhr = WearableJSON.posInt(e, "value") }
                    guard let rhr else { continue }
                    var row = day(key); row.restingHr = rhr; byDay[key] = row
                }
            } else if base.hasPrefix("steps") || base.contains("steps") {
                // A per-day file holds intraday step events; the daily total is their sum.
                var totals: [String: Int] = [:]
                for e in WearableJSON.array(data)?.compactMap({ $0 as? [String: Any] }) ?? [] {
                    guard let key = dayKey(WearableJSON.str(e, "dateTime")),
                          let v = WearableJSON.int(e, "value"), v >= 0 else { continue }
                    totals[key, default: 0] += v
                }
                for (key, total) in totals where total > 0 {
                    var row = day(key)
                    row.steps = (row.steps ?? 0) + total
                    byDay[key] = row
                }
            }
        }
        return (Array(byDay.values), sleeps)
    }

    // MARK: - Helpers

    private static func sleepSession(_ log: [String: Any]) -> WearableSleepSession? {
        guard let start = fitbitTime(WearableJSON.str(log, "startTime")),
              let end = fitbitTime(WearableJSON.str(log, "endTime")),
              end > start else { return nil }

        // levels.summary.{deep,light,rem,wake}.minutes — the modern "stages" log. Falls back to the
        // legacy "asleep/restless/awake" summary when stages are absent (older Fitbit devices).
        var deep: Double?, light: Double?, rem: Double?, wake: Double?
        var stages: [WearableSleepStageInterval] = []
        if let levels = log["levels"] as? [String: Any] {
            if let summary = levels["summary"] as? [String: Any] {
                deep = stageMinutes(summary, "deep")
                light = stageMinutes(summary, "light")
                rem = stageMinutes(summary, "rem")
                wake = stageMinutes(summary, "wake")
            }
            // Optional per-segment hypnogram (levels.data[]): dateTime, level, seconds.
            if let segs = levels["data"] as? [[String: Any]] {
                for seg in segs.prefix(100_000) {
                    guard let s = fitbitTime(WearableJSON.str(seg, "dateTime")),
                          let secs = WearableJSON.posDbl(seg, "seconds"),
                          let lvl = WearableJSON.str(seg, "level") else { continue }
                    let e = s.addingTimeInterval(secs)
                    if e > s { stages.append(WearableSleepStageInterval(stage: stageName(lvl), start: s, end: e)) }
                }
            }
        }

        let asleep = WearableJSON.posDbl(log, "minutesAsleep")
        let awakeMin = wake ?? WearableJSON.posDbl(log, "minutesAwake")

        return WearableSleepSession(
            start: start,
            end: end,
            deepMin: deep,
            lightMin: light,
            remMin: rem,
            awakeMin: awakeMin,
            totalSleepMin: asleep,
            efficiencyPct: WearableJSON.posDbl(log, "efficiency"),
            avgHr: nil,                 // Takeout sleep logs carry no avg HR
            lowestHr: nil,
            avgHrvMs: nil,
            respRateBpm: nil,
            sleepScore: nil,
            stages: stages.sorted { $0.start < $1.start })
    }

    private static func stageMinutes(_ summary: [String: Any], _ key: String) -> Double? {
        guard let obj = summary[key] as? [String: Any] else { return nil }
        return WearableJSON.posDbl(obj, "minutes")
    }

    private static func stageName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "deep": return "deep"
        case "rem": return "rem"
        case "light", "asleep": return "light"
        default: return "wake"   // "wake", "awake", "restless" → wake
        }
    }

    /// Parse a Fitbit local timestamp into a `Date`. Fitbit Takeout times carry NO offset and often a
    /// `.SSS` fraction (e.g. `2026-05-31T23:00:00.000`). `WhoopTime`'s ISO formatters require an offset,
    /// so we interpret the wall-clock at UTC (Fitbit is offsetless; the day is keyed off `dateOfSleep`).
    static func fitbitTime(_ raw: String?) -> Date? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let d = WhoopTime.parse(t, offsetMinutes: 0) { return d }   // handles offset-bearing forms
        let normalized = t.replacingOccurrences(of: "T", with: " ")
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            altFormatter.dateFormat = pattern
            if let d = altFormatter.date(from: normalized) { return d }
        }
        return nil
    }

    /// Fitbit `dateTime` is either an ISO instant or `MM/dd/yy HH:mm:ss`. We only need the calendar day.
    private static func dayKey(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if let d = fitbitTime(t) { return WearableExportImporter.dayString(d) }
        // "MM/dd/yy ..." (Fitbit's older intraday format).
        for pattern in ["MM/dd/yy HH:mm:ss", "MM/dd/yy", "yyyy-MM-dd"] {
            altFormatter.dateFormat = pattern
            if let d = altFormatter.date(from: t) { return WearableExportImporter.dayString(d) }
        }
        // Last resort: a bare leading yyyy-MM-dd.
        if t.count >= 10 { return String(t.prefix(10)) }
        return nil
    }

    private static let altFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
