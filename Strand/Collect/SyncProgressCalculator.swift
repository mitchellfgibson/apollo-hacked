import Foundation

// MARK: - Sync-ring progress (fork-local)
//
// The math behind the Settings sync ring, kept pure and free of CoreBluetooth/SwiftUI so it can be
// unit-tested directly. `BLEManager.recomputeSyncProgress()` is the only caller; it supplies the
// numbers read from the store and publishes the result onto `LiveState.syncProgress`.

enum SyncProgressCalculator {

    /// How stale the newest record may be while still counting as fully caught-up (90 min).
    /// A strap synced within the last hour and a half is "live": the ring should read full rather
    /// than nervously ticking down between offloads.
    static let liveWithinSeconds = 90 * 60

    /// The window the ring measures against — the strap's stored-history depth (~14 days).
    static let windowSeconds = 14 * 24 * 3600

    /// Combine wear-completeness with freshness into a single 0…1 ring value.
    ///
    /// - `behind`: seconds our newest record lags the present (nil ⇒ nothing stored ⇒ 0).
    /// - `covered` / `smallHoles`: hour counts from `WhoopStore.wearCompleteness`.
    ///
    /// COMPLETENESS is the fraction of *worn* hours actually pulled, so off-wrist time never drags
    /// it down. FRESHNESS is 1.0 while the newest record is within `liveWithinSeconds`, ramping to 0
    /// as it recedes toward the full window — that is what stops a strap we lost contact with days
    /// ago from reading "complete" off stale history. The two are multiplied, so a big mid-session
    /// hole OR a stale frontier each visibly pull the ring down; it is honest either way.
    static func progress(behind: Int?, covered: Int, smallHoles: Int,
                         window: Int = windowSeconds,
                         liveWithin: Int = liveWithinSeconds) -> Double {
        guard let behind else { return 0 }

        let worn = covered + smallHoles
        let completeness: Double = worn > 0 ? Double(covered) / Double(worn) : 0

        let freshness: Double
        if behind <= liveWithin {
            freshness = 1.0
        } else if window > liveWithin {
            freshness = max(0, min(1, Double(window - behind) / Double(window - liveWithin)))
        } else {
            freshness = 0
        }

        return max(0, min(1, completeness * freshness))
    }
}
