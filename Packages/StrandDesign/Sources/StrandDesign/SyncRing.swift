import SwiftUI

/// A small circular progress ring that slowly fills as the app catches up on the strap's stored
/// data — like a data-usage meter. Empty = far behind; full = "live" (caught up). No spin, no
/// sweep: the arc just grows from empty to full to represent percent-done. Brand-neutral; drop it
/// anywhere a compact "how caught-up am I" indicator is wanted (currently the Settings strap card).
public struct SyncRing: View {
    /// 0…1 — how caught up we are (1 = live / full).
    public let progress: Double
    /// Diameter in points.
    public let size: CGFloat

    public init(progress: Double, size: CGFloat = 44) {
        self.progress = progress
        self.size = size
    }

    private var isLive: Bool { progress >= 0.999 }
    @State private var animatedProgress: Double = 0

    private var tint: Color { isLive ? StrandPalette.accent : StrandPalette.recovery055 }

    public var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(StrandPalette.hairline, lineWidth: size * 0.09)

            // Filled arc — grows clockwise from 12 o'clock with the catch-up fraction.
            Circle()
                .trim(from: 0, to: animatedProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Center: a small percentage while filling; a checkmark once full ("live").
            if isLive {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.3, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: size * 0.26, weight: .semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(StrandMotion.drawIn) { animatedProgress = progress }
        }
        .onChange(of: progress) { newValue in
            // Ease smoothly to the new fill level — the "slowly fills up" feel, no spinning.
            withAnimation(.easeInOut(duration: 0.6)) { animatedProgress = newValue }
        }
        .accessibilityElement()
        .accessibilityLabel("Data sync")
        .accessibilityValue(isLive ? "Live — caught up" : "\(Int(progress * 100)) percent caught up")
    }
}
