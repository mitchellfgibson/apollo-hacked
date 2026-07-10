import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"          // merged: Today + Live
    case intelligence = "Intelligence" // merged: Intelligence + Stress
    case explore = "Explore"
    case sleep = "Sleep"
    case trends = "Trends"
    case health = "Health"
    case settings = "Settings"    // the old "Data" page now lives inside Settings

    var id: String { rawValue }

    /// Tabs shown at the bottom. Same set on every platform now that the desktop-only
    /// destinations (Automations, Notifications) have been removed.
    static var visible: [NavItem] { allCases }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .intelligence: return "brain.head.profile"
        case .explore: return "square.grid.2x2.fill"
        case .sleep: return "moon.stars.fill"
        case .trends: return "chart.xyaxis.line"
        case .health: return "heart.text.square.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream).
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem = .today

    var body: some View {
        TabView(selection: $selection) {
            ForEach(NavItem.visible) { item in
                screen(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .tabItem {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                    .tag(item)
            }
        }
        .tint(StrandPalette.accent)
        .task { await repo.refresh() }
    }

    @ViewBuilder private func screen(for item: NavItem) -> some View {
        switch item {
        case .today: TodayLiveView()
        case .intelligence: IntelligenceStressView()
        case .explore: MetricExplorerView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .health: HealthView()
        case .settings: SettingsView()
        }
    }
}

/// Isolated live-status pill — owns the LiveState observation so nothing else re-renders on
/// the ~1 Hz HR / frame stream. Kept for reuse (menu bar, headers) after the sidebar removal.
struct SidebarStatus: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .shadow(color: statusColor.opacity(0.6), radius: live.connected ? 4 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(live.batteryPct.map { "Battery \(Int($0))%" } ?? "Strap not connected")
                    .font(.system(size: 11))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
        }
        .padding(10)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        live.bonded ? StrandPalette.statusPositive
            : live.connected ? StrandPalette.statusWarning
            : StrandPalette.statusCritical
    }
    private var statusText: String {
        live.bonded ? "WHOOP · Bonded" : live.connected ? "Connecting…" : "Disconnected"
    }
}
