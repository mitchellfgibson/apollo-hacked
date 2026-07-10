import Foundation
import Combine

/// Observable snapshot of the live connection + biometric state, driven by FrameRouter
/// (from decoded frames) and BLEManager (from CoreBluetooth callbacks).
/// `@MainActor` so SwiftUI views observe it safely; mutators are called on the main queue.
@MainActor
public final class LiveState: ObservableObject {
    @Published public var connected: Bool = false
    @Published public var bonded: Bool = false
    @Published public var heartRate: Int? = nil
    @Published public var rr: [Int] = []
    @Published public var batteryPct: Double? = nil
    @Published public var lastFrameType: String? = nil
    @Published public var lastEvent: String? = nil
    /// Wrist-wear state from WRIST_ON/WRIST_OFF events. Defaults true so wear-gated features work
    /// before the first event arrives; flipped by FrameRouter on a real event.
    @Published public var worn: Bool = true
    /// Rolling log of human-readable lines for the on-device verification checklist.
    @Published public var log: [String] = []

    /// Fired (live only) when the strap reports a DOUBLE_TAP gesture. Wired by AppModel to the
    /// user's chosen action. Debounced in AppModel.
    public var onDoubleTap: (() -> Void)?
    /// Fired (live only) when wrist-wear changes (true = put on, false = taken off).
    public var onWristChange: ((Bool) -> Void)?

    /// True when the stuck-strap watchdog finds the strap has newer records than us but our frontier
    /// won't advance (likely needs a manual reboot; ~never after high-freq-sync removal). Banner-only.
    @Published public var strapNeedsReboot = false

    /// Wall time (unix seconds) of the last successfully-completed offload (a sync, even if nothing new
    /// came — i.e. caught up). Drives the sync tile + the staleness nudge.
    @Published public var lastSyncedAt: TimeInterval?

    /// True while a historical offload (backfill) is actively pulling the strap's stored data.
    @Published public var backfilling = false

    /// Sync progress 0…1 — the fraction of the strap's ~14-day stored window that we've actually
    /// offloaded, measured by HOUR COVERAGE (distinct hours with data ÷ hours in the window). This
    /// reflects real completeness including GAPS in the middle — unlike a frontier check, which reads
    /// "caught up" whenever live HR keeps the newest record fresh even with a week of holes behind it.
    /// Recomputed by BLEManager after each offload + on a timer; NOT derived per-render.
    @Published public var syncProgress: Double = 0

    /// True only when we've pulled essentially the whole stored window (the ring is "live" / full).
    public var isLive: Bool { syncProgress >= 0.98 }

    /// Optional hook invoked on every battery update (wired by LiveViewModel to the alert monitor).
    /// Kept as a closure so LiveState stays a plain observable snapshot with no alert dependency.
    public var onBatteryUpdate: ((Double) -> Void)?

    public init() {}

    /// True only while the strap link is CURRENTLY live enough to use the app. The gate waits on this.
    ///
    /// It must require `connected` (which drops to false on disconnect), because `heartRate`,
    /// `lastFrameType` and `lastEvent` are sticky — they keep their last value after a disconnect,
    /// so testing them alone would latch the gate open forever even once the strap is gone. So:
    ///   • WHOOP 4: a real bond (`bonded`) while connected, OR
    ///   • WHOOP 5/MG (never flips `bonded`): connected AND data actively relaying right now
    ///     (a live heart rate present on the current connection).
    public var gatePassed: Bool {
        guard connected else { return false }
        return bonded || heartRate != nil
    }

    /// Single funnel for battery readings — updates the published value AND notifies the hook,
    /// so both write sites (FrameRouter, BLEManager) drive the alert monitor identically.
    public func setBattery(_ pct: Double) {
        batteryPct = pct
        onBatteryUpdate?(pct)
    }

    public func append(log line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
