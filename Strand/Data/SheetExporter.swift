import Foundation
import WhoopStore

/// One-button export of the analysis-ready DAILY rows (resting HR, HRV, HR range, recovery, strain,
/// sleep) to a Google Sheet via a Google Apps Script Web App. The app is a holding cell + connector:
/// it captures + computes on-device and ships one row per day out; all trend analysis lives in the
/// Sheet. No OAuth / Google Cloud project — the Apps Script (deployed as the user) does the write.
///
/// "Only unsent" = a local watermark (last exported day) advances on success, but each run also
/// re-sends a trailing overlap window so nights that were RECOMPUTED (a fallback-staged night
/// upgrading to full staging once its motion offloads) overwrite their Sheet row. The Apps Script
/// upserts by date, so re-sending is idempotent and never duplicates.
@MainActor
final class SheetExporter: ObservableObject {
    private let repo: Repository
    private let deviceId: String
    private var computedDeviceId: String { deviceId + "-noop" }

    @Published var busy = false
    @Published var lastStatus: String?

    // Config + watermark live in UserDefaults (app-side only; no schema change).
    private let urlKey = "sheet.exportURL"
    private let tokenKey = "sheet.exportToken"
    private let watermarkKey = "sheet.lastExportedDay"     // "YYYY-MM-DD"
    private let lastRunKey = "sheet.lastRunAt"
    private let autoKey = "sheet.autoExport"
    private let lastAutoKey = "sheet.lastAutoAt"

    /// Days re-sent below the watermark so recomputed nights overwrite in the Sheet.
    private let overlapDays = 14
    /// Auto-export holds off until this many days of REAL data (a scored night with resting HR + HRV)
    /// exist, so the Sheet isn't seeded with sparse warmup days before there's a baseline to analyze.
    private let minRealDays = 3
    /// Don't auto-fire more than once per this interval (guards the analyzeRecent cadence).
    private let autoMinInterval: TimeInterval = 30 * 60

    init(repo: Repository, deviceId: String) {
        self.repo = repo; self.deviceId = deviceId
    }

    var exportURL: String {
        get { UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey) }
    }
    var exportToken: String {
        get { UserDefaults.standard.string(forKey: tokenKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: tokenKey) }
    }
    var isConfigured: Bool { !exportURL.isEmpty && !exportToken.isEmpty }

    /// Auto-export toggle. Defaults ON (the user asked for it) but only acts once configured AND the
    /// 3-real-day gate is met; before that it's inert, so turning it on early does nothing surprising.
    var autoExportEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    // MARK: - Auto-export

    /// Called after each recompute (app launch, the 15-min loop, and post-backfill). Fires an export
    /// only when: enabled + configured, ≥3 real days exist, at least a new day has landed since the
    /// last export, and the rate limit has elapsed. All cheap checks before any network use.
    func autoExportIfDue() async {
        guard autoExportEnabled, isConfigured, !busy else { return }
        let last = UserDefaults.standard.object(forKey: lastAutoKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= autoMinInterval else { return }
        guard let store = await repo.storeHandle() else { return }

        let today = Self.dayFormatter.string(from: Date())
        let metrics = (try? await store.dailyMetrics(deviceId: computedDeviceId,
                                                     from: "2000-01-01", to: today)) ?? []
        // "Real" day = a scored night (both resting HR and HRV present).
        let realDays = metrics.filter { $0.restingHr != nil && $0.avgHrv != nil }.count
        guard realDays >= minRealDays else { return }

        // Only auto-fire when there's genuinely a newer day than we've already pushed. Recompute-only
        // changes to already-sent days ride along on the next new-day export via the overlap window.
        let watermark = UserDefaults.standard.string(forKey: watermarkKey) ?? ""
        let newest = metrics.map(\.day).max() ?? ""
        guard newest > watermark else { return }

        UserDefaults.standard.set(Date(), forKey: lastAutoKey)
        await exportNow()
    }

    // MARK: - Export

    /// Assemble every day at/after (watermark − overlap) and POST it. Advances the watermark on 200.
    func exportNow() async {
        guard !busy else { return }
        guard isConfigured, let url = URL(string: exportURL) else {
            lastStatus = "Set the Sheet URL and token first."; return
        }
        busy = true; defer { busy = false }

        guard let store = await repo.storeHandle() else { lastStatus = "Store not ready."; return }

        let today = AnalyticsEngine_dayString(Date())
        let from = startDay()
        let metrics = (try? await store.dailyMetrics(deviceId: computedDeviceId, from: from, to: today)) ?? []
        guard !metrics.isEmpty else { lastStatus = "No computed days to export yet."; return }

        let hrStats = (try? await store.dailyHRStats(deviceId: deviceId, fromDay: from, toDay: today)) ?? []
        let hrByDay = Dictionary(uniqueKeysWithValues: hrStats.map { ($0.day, $0) })

        let stamp = ISO8601DateFormatter().string(from: Date())
        let rows: [[String: Any]] = metrics.map { m in
            let hr = hrByDay[m.day]
            // "full" once motion-based staging has produced deep/REM; else the HR-only fallback.
            let staged = ((m.deepMin ?? 0) > 0 || (m.remMin ?? 0) > 0) ? "full" : "hr-fallback"
            var row: [String: Any] = [
                "date": m.day,
                "staging_source": staged,
                "exported_at": stamp,
            ]
            row["resting_hr"]       = m.restingHr as Any?
            row["hrv_ms"]           = m.avgHrv.map { round($0 * 10) / 10 } as Any?
            row["recovery"]         = m.recovery.map { round($0 * 10) / 10 } as Any?
            row["strain"]           = m.strain.map { round($0 * 10) / 10 } as Any?
            row["sleep_min"]        = m.totalSleepMin.map { Int($0.rounded()) } as Any?
            row["sleep_efficiency"] = m.efficiency.map { round($0 * 100) / 100 } as Any?
            row["skin_temp_dev_c"]  = m.skinTempDevC.map { round($0 * 100) / 100 } as Any?
            row["resp_bpm"]         = m.respRateBpm.map { round($0 * 10) / 10 } as Any?
            row["spo2"]             = m.spo2Pct as Any?
            row["hr_min"]           = hr?.min as Any?
            row["hr_max"]           = hr?.max as Any?
            row["hr_avg"]           = hr.map { Int($0.avg.rounded()) } as Any?
            row["hr_sample_count"]  = hr?.count as Any?
            return row.compactMapValues { $0 is NSNull ? nil : $0 }
        }

        do {
            let (inserted, updated) = try await post(url: url, rows: rows)
            if let maxDay = metrics.map(\.day).max() {
                UserDefaults.standard.set(maxDay, forKey: watermarkKey)
            }
            UserDefaults.standard.set(Date(), forKey: lastRunKey)
            lastStatus = "Sent \(rows.count) days (\(inserted) new, \(updated) updated)."
        } catch {
            lastStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Human-readable last-run line for the Settings row.
    var lastRunSummary: String? {
        guard let at = UserDefaults.standard.object(forKey: lastRunKey) as? Date else { return nil }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        let wm = UserDefaults.standard.string(forKey: watermarkKey)
        return "Last export \(f.localizedString(for: at, relativeTo: Date()))"
            + (wm.map { " · through \($0)" } ?? "")
    }

    // MARK: - internals

    private func startDay() -> String {
        guard let wm = UserDefaults.standard.string(forKey: watermarkKey),
              let wmDate = Self.dayFormatter.date(from: wm) else {
            return "2000-01-01"   // first run → whole history
        }
        let back = Calendar.current.date(byAdding: .day, value: -overlapDays, to: wmDate) ?? wmDate
        return Self.dayFormatter.string(from: back)
    }

    private func post(url: URL, rows: [[String: Any]]) async throws -> (inserted: Int, updated: Int) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["token": exportToken, "rows": rows])
        req.timeoutInterval = 60

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ExportError.badResponse }
        // Apps Script 302-redirects to googleusercontent; URLSession follows it automatically.
        guard (200...299).contains(http.statusCode) else { throw ExportError.status(http.statusCode) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let ok = obj?["ok"] as? Bool, ok == false {
            throw ExportError.script((obj?["error"] as? String) ?? "unknown")
        }
        return (obj?["inserted"] as? Int ?? 0, obj?["updated"] as? Int ?? 0)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func AnalyticsEngine_dayString(_ date: Date) -> String { Self.dayFormatter.string(from: date) }

    enum ExportError: LocalizedError {
        case badResponse, status(Int), script(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "no HTTP response"
            case .status(let c): return "HTTP \(c)"
            case .script(let s): return s
            }
        }
    }
}
