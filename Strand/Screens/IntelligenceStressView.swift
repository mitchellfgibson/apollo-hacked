import SwiftUI
import StrandDesign

/// Merged Intelligence + Stress screen. A segmented control at the top switches between the
/// on-device recovery/strain/sleep scores (Intelligence) and the autonomic-load view (Stress),
/// which used to be two separate sidebar destinations. Each sub-view keeps its own
/// ScreenScaffold, so this wrapper only owns the mode toggle.
struct IntelligenceStressView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case intelligence = "Scores"
        case stress = "Stress"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .intelligence

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
            case .intelligence: IntelligenceView()
            case .stress: StressView()
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}
