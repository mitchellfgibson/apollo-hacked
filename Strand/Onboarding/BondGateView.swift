import SwiftUI
import StrandDesign

// A blocking "bond gate": the app is unusable until the strap is bonded AND data has started
// flowing over the session. It walks through the stages (connecting → bonding → receiving data)
// and dismisses itself once `live.gatePassed` becomes true. For WHOOP 5/MG — whose handshake never
// sets `bonded` — "gate passed" is proven by real data arriving (live HR / a decoded frame), which
// is exactly "wait for data to be relayed through bonding until disappearing".
//
// Placeholder scope for now: a clean status screen. Later this becomes the full guided walkthrough.
struct BondGateView: View {
    @EnvironmentObject var live: LiveState
    /// Optional notification that the gate is satisfied. Dismissal itself is driven reactively by
    /// the host (ContentView) observing `live.gatePassed`; this is just a hook if callers want it.
    var onPassed: () -> Void = {}

    /// Ordered stages the user progresses through.
    private enum Stage { case searching, connecting, receiving, done }

    private var stage: Stage {
        if live.gatePassed { return .done }
        if live.connected { return .receiving }   // linked; waiting for the first data over the session
        return .searching
    }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                PulseRing(active: stage != .done)
                    .frame(width: 180, height: 180)

                VStack(spacing: 10) {
                    Text(title)
                        .font(StrandFont.title1)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                stageChecklist
                    .padding(.top, 4)

                Spacer()

                if let hr = live.heartRate {
                    // Immediate proof data is flowing — the thing the gate waits for.
                    Text("\(hr) BPM")
                        .font(StrandFont.serifBold(20))
                        .foregroundStyle(StrandPalette.accent)
                        .transition(.opacity)
                        .padding(.bottom, 24)
                }
            }
            .padding(32)
        }
        .animation(.easeInOut(duration: 0.4), value: stage)
        .onChange(of: live.gatePassed) { passed in
            if passed {
                // Small beat so the user sees the "receiving data" confirmation before it dismisses.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onPassed() }
            }
        }
        .onAppear { if live.gatePassed { onPassed() } }
    }

    private var title: String {
        switch stage {
        case .searching:  return "Finding your strap"
        case .connecting: return "Connecting"
        case .receiving:  return "Waiting for your data"
        case .done:       return "You're in"
        }
    }

    private var subtitle: String {
        switch stage {
        case .searching:  return "Make sure your WHOOP is nearby and charged."
        case .connecting: return "Establishing a secure link over Bluetooth."
        case .receiving:  return "Bonded. Waiting for the first readings to come through."
        case .done:       return "Data is flowing. Opening NOOP…"
        }
    }

    @ViewBuilder private var stageChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            checkRow("Strap connected", done: live.connected)
            checkRow("Bonded", done: live.connected)   // linked = bonded from the user's POV
            checkRow("Receiving data", done: live.gatePassed)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func checkRow(_ label: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? StrandPalette.accent : StrandPalette.hairlineStrong)
                .font(.system(size: 18))
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(done ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        }
    }
}

/// A calm concentric pulse used while the gate is waiting; goes still when passed.
private struct PulseRing: View {
    var active: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(StrandPalette.accent.opacity(0.35), lineWidth: 2)
                    .scaleEffect(animate ? 1.0 : 0.55)
                    .opacity(animate ? 0.0 : 0.8)
                    .animation(
                        active
                            ? .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(i) * 0.7)
                            : .default,
                        value: animate)
            }
            Circle()
                .fill(StrandPalette.accentMuted)
                .frame(width: 84, height: 84)
            Image(systemName: active ? "dot.radiowaves.left.and.right" : "checkmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
        }
        .onAppear { animate = active }
        .onChange(of: active) { animate = $0 }
    }
}
