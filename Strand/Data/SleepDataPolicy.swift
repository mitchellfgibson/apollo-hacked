import Foundation

/// Splits the user's data into "past" (imported 2024/2025 history) and "present" (from the
/// cutover onward), and controls whether the app includes the past.
///
/// The boundary is a fixed calendar date — **June 10, 2026**. When `includePast` is ON the app
/// shows past + present; when OFF it shows present only. The filter is applied once, in the
/// Repository, so every screen (Today, Trends, Sleep, Explore, Health) honours it app-wide.
enum HistoryFilter {
    /// UserDefaults key for the toggle (default ON — show everything).
    static let includePastKey = "noop.includePastData"

    /// The fixed past/present boundary: 2026-06-10 (UTC midnight), as unix seconds.
    static let cutoverTs: Int = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 10
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return Int((cal.date(from: c) ?? Date(timeIntervalSince1970: 1_749_513_600)).timeIntervalSince1970)
    }()

    /// The boundary as a `yyyy-MM-dd` day string, for filtering `DailyMetric.day`.
    static let cutoverDay = "2026-06-10"

    /// Human-readable boundary date for UI copy.
    static var cutoverLabel: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(cutoverTs)))
    }

    /// Whether the user currently wants past data included.
    static var includePast: Bool {
        UserDefaults.standard.object(forKey: includePastKey) as? Bool ?? true
    }

    /// A daily row is "present" when its day is on or after the boundary.
    static func isPresent(day: String) -> Bool { day >= cutoverDay }

    /// A sleep session is "present" when it starts on or after the boundary.
    static func isPresent(sessionStartTs: Int) -> Bool { sessionStartTs >= cutoverTs }
}
