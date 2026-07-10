import SwiftUI

/// Root — the sidebar shell, with the first-run onboarding/pairing wizard overlaid until complete,
/// and a bond gate that blocks all use until the strap is bonded and data is flowing.
struct ContentView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @EnvironmentObject private var live: LiveState

    var body: some View {
        ZStack {
            RootView()
            if !onboarded {
                OnboardingWizard(onFinished: { onboarded = true })
                    .transition(.opacity)
                    .zIndex(1)
            }
            // The gate blocks all use whenever the strap link is not currently live (`gatePassed`
            // requires connected + bonded/streaming). It is driven purely by live state — NOT a
            // sticky flag — so it correctly re-appears if the strap disconnects or was never bonded,
            // and only disappears while the link is actually relaying data.
            if onboarded && !live.gatePassed {
                BondGateView(onPassed: {})
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: onboarded)
        .animation(.easeInOut(duration: 0.4), value: live.gatePassed)
    }
}
