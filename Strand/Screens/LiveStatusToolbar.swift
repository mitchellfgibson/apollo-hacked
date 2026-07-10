import SwiftUI
import StrandDesign

/// The top-right toolbar status control. Replaces the old Support heart with a live readout of
/// the strap connection: a color-coded pill (disconnected / connecting / bonded) that opens a
/// popover detailing whether data is actually transferring — battery, live HR, wrist wear, the
/// last frame received (proof the stream is flowing), and the last completed sync.
struct LiveStatusToolbar: View {
    @EnvironmentObject private var live: LiveState
    @State private var showingDetail = false

    var body: some View {
        Button { showingDetail.toggle() } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.6), radius: live.bonded ? 3 : 0)
                Text(shortLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(StrandPalette.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Strap connection & data transfer")
        .accessibilityLabel("Strap status: \(shortLabel)")
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
            LiveStatusPopover().environmentObject(live)
        }
    }

    private var statusColor: Color {
        live.bonded ? StrandPalette.statusPositive
            : live.connected ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var shortLabel: String {
        live.bonded ? "Live" : live.connected ? "Connecting" : "Offline"
    }
}

/// The detail popover: everything about the current link and whether data is moving.
private struct LiveStatusPopover: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — connection headline + battery.
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .shadow(color: statusColor.opacity(0.6), radius: live.bonded ? 4 : 0)
                Text(statusHeadline)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if let batt = live.batteryPct {
                    Label("\(Int(batt))%", systemImage: batterySymbol(batt))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }

            Divider().overlay(StrandPalette.hairline)

            VStack(alignment: .leading, spacing: 9) {
                row("Connection", value: connectionValue, ok: live.connected)
                row("Bonded", value: live.bonded ? "Yes" : "No", ok: live.bonded)
                row("Wrist", value: live.worn ? "On wrist" : "Off wrist", ok: live.worn)
                row("Live heart rate",
                    value: live.heartRate.map { "\($0) bpm" } ?? "—",
                    ok: live.heartRate != nil)
                row("Data transfer",
                    value: transferValue,
                    ok: live.lastFrameType != nil)
                if let frame = live.lastFrameType {
                    row("Last frame", value: frame, ok: true)
                }
                row("Last sync", value: lastSyncValue, ok: live.lastSyncedAt != nil)
            }

            if live.strapNeedsReboot {
                Text("Strap has newer records than we've pulled — a manual strap reboot may be needed.")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !live.connected {
                Text("No strap connected. Make sure it's disconnected from any phone and in range.")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 288)
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ok ? StrandPalette.textPrimary : StrandPalette.textTertiary)
        }
    }

    // MARK: - Derived values

    private var statusColor: Color {
        live.bonded ? StrandPalette.statusPositive
            : live.connected ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var statusHeadline: String {
        live.bonded ? "Strap connected" : live.connected ? "Connecting…" : "Not connected"
    }
    private var connectionValue: String {
        live.bonded ? "Bonded" : live.connected ? "Linking" : "Disconnected"
    }
    private var transferValue: String {
        guard live.connected else { return "Idle" }
        return live.lastFrameType != nil ? "Streaming" : "Waiting for frames"
    }
    private var lastSyncValue: String {
        guard let t = live.lastSyncedAt else { return "Never" }
        let elapsed = Date().timeIntervalSince1970 - t
        if elapsed < 60 { return "Just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86_400))d ago"
    }
    private func batterySymbol(_ pct: Double) -> String {
        switch pct {
        case ..<12.5: return "battery.0percent"
        case ..<37.5: return "battery.25percent"
        case ..<62.5: return "battery.50percent"
        case ..<87.5: return "battery.75percent"
        default:      return "battery.100percent"
        }
    }
}
