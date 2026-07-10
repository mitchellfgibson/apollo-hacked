import SwiftUI
import StrandDesign

/// Merged Today + Live screen. A segmented control at the top switches between the home
/// dashboard (Today) and the real-time strap view (Live), which used to be two separate
/// sidebar destinations. Each sub-view keeps its own ScreenScaffold, so this wrapper only
/// owns the mode toggle and hands off to the existing, unchanged screens.
struct TodayLiveView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case today = "Today"
        case live = "Live"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .today

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .background(StrandPalette.surfaceBase)

            switch mode {
            case .today: TodayView()
            case .live: LiveView()
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}
