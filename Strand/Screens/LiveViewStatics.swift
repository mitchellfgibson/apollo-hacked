import SwiftUI
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign

// MARK: - LiveView statics carried from upstream
//
// Upstream declares these as statics on ITS `LiveView`. This fork keeps its own version of that screen,
// while upstream's other files and tests still reach them through `LiveView.…`, so the ones this tree
// actually calls are carried here verbatim. Pure projections — no view state.

extension LiveView {

    /// Whether the low-bandwidth standard-HR fallback note should render. The note explains that live HR
    /// is coming over the standard BLE Heart-Rate profile because the radio couldn't sustain the full
    /// stream (#80). Shown only when LiveState carries a non-empty note string; pure so it's unit-testable
    /// without standing up a SwiftUI view.
    static func shouldShowStandardHRNote(_ note: String?) -> Bool {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }
}
