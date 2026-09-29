import XCTest
@testable import Strand

/// Regression guard for the "New data added" inbox spam (#521). The Today screen announces new history
/// by posting a `.reading` `UpdateItem` to the shared `UpdateStore`; background recompute ticks used to
/// re-post it on a loop. The store's own dedup + cap is the backstop that guarantees a repeated identical
/// informational post collapses to a SINGLE row rather than piling up. Mirrors the intent of the Android
/// `UpdateStore.post` logic (kept in lock-step by hand).
@MainActor
final class UpdateInboxDedupTests: XCTestCase {

    /// A `.reading` "New data added" post, matching `TodayView.announceNewDaysIfNeeded`'s shape.
    private func reading(_ msg: String = "1 new day of history landed. Open Trends to see it.",
                         at date: Date = Date()) -> UpdateItem {
        UpdateItem(kind: .reading, title: "New data added", message: msg,
                   date: date, deepLink: NavRouter.Destination.trends.rawValue)
    }

    override func setUp() {
        super.setUp()
        UpdateStore.shared.clearAll()
    }

    override func tearDown() {
        UpdateStore.shared.clearAll()
        super.tearDown()
    }

    /// The core #521 fix: posting the SAME `.reading` item many times in a tight window (as the old
    /// recompute churn did) collapses to exactly ONE inbox row, not N.
    func testRepeatedIdenticalReadingCollapsesToOne() {
        let store = UpdateStore.shared
        for _ in 0..<25 { store.post(reading()) }
        let readings = store.items.filter { $0.kind == .reading }
        XCTAssertEqual(readings.count, 1, "Repeated identical .reading posts must dedupe to a single row")
    }

    /// A genuinely-newer announcement (different message, same kind+deepLink) still collapses onto the
    /// existing row in-window — the badge re-arms and the date/message refresh — so the inbox never grows
    /// a second "New data" row for the same Trends link within the dedup window.
    func testInWindowReadingUpdatesExistingRow() {
        let store = UpdateStore.shared
        store.post(reading("1 new day of history landed. Open Trends to see it."))
        store.post(reading("3 new days of history landed. Open Trends to see them."))
        let readings = store.items.filter { $0.kind == .reading }
        XCTAssertEqual(readings.count, 1)
        XCTAssertEqual(readings.first?.message, "3 new days of history landed. Open Trends to see them.")
        XCTAssertFalse(readings.first?.read ?? true, "A collapsed update re-arms the unread badge")
    }

    /// A `.reading` post OUTSIDE the dedup window is a fresh row (a real new-data event days later).
    func testOutOfWindowReadingAppendsNewRow() {
        let store = UpdateStore.shared
        let old = Date().addingTimeInterval(-2 * 60 * 60)   // 2h ago — beyond the 30-min window
        store.post(reading(at: old))
        store.post(reading())                                // now
        XCTAssertEqual(store.items.filter { $0.kind == .reading }.count, 2)
    }

    /// The cap evicts the oldest informational rows so the inbox can't grow unbounded. Posting 60 DISTINCT
    /// `.reading` rows (spaced beyond the dedup window so each is its own row) leaves at most the cap.
    func testInformationalBacklogIsCapped() {
        let store = UpdateStore.shared
        let base = Date().addingTimeInterval(-1000 * 60 * 60)   // far in the past, then walk forward
        for i in 0..<60 {
            // 31 minutes apart → each is outside the previous one's dedup window → a distinct row.
            store.post(reading("day \(i)", at: base.addingTimeInterval(Double(i) * 31 * 60)))
        }
        let readings = store.items.filter { $0.kind == .reading }
        XCTAssertLessThanOrEqual(readings.count, 50, "Informational backlog must be capped at 50")
        // The NEWEST rows survive — the very last message must still be present.
        XCTAssertTrue(store.items.contains { $0.message == "day 59" }, "Newest rows are kept on eviction")
        XCTAssertFalse(store.items.contains { $0.message == "day 0" }, "Oldest rows are evicted first")
    }

    /// Actionable rows (a dismissed Today card) are NEVER auto-evicted by the informational cap — the user
    /// owns those. Even past the cap of `.reading` rows, a `.dismissedCard` survives.
    func testActionableRowsSurviveEviction() {
        let store = UpdateStore.shared
        store.post(UpdateItem(kind: .dismissedCard, title: "Scores building",
                              message: "Restorable", restorePayload: "scoresBuilding"))
        let base = Date().addingTimeInterval(-1000 * 60 * 60)
        for i in 0..<60 {
            store.post(reading("day \(i)", at: base.addingTimeInterval(Double(i) * 31 * 60)))
        }
        XCTAssertTrue(store.items.contains { $0.kind == .dismissedCard },
                      "Dismissed-card rows must never be auto-evicted by the informational cap")
    }
}
