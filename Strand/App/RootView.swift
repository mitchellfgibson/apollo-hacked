import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case intelligence = "Intelligence"
    case coach = "Coach"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case appleHealth = "Apple Health"
    case dataSources = "Data Sources"
    case notifications = "Notifications"
    case automation = "Automations"
    case settings = "Settings"
    case support = "Support"

    var id: String { rawValue }

    /// Items shown in the sidebar for the current platform. Automations (Mac screen-lock /
    /// Shortcuts) and Notifications (mirroring installed *Mac* apps to the wrist) are desktop-only
    /// and have no iPhone equivalent, so they're hidden on iOS.
    static var visible: [NavItem] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { $0 != .automation && $0 != .notifications }
        #endif
    }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .intelligence: return "brain.head.profile"
        case .coach: return "sparkles"
        case .live: return "waveform.path.ecg"
        case .breathe: return "lungs.fill"
        case .intervals: return "timer"
        case .explore: return "square.grid.2x2.fill"
        case .compare: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.fill"
        case .sleep: return "moon.stars.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.50percent"
        case .appleHealth: return "heart.fill"
        case .dataSources: return "square.and.arrow.down.fill"
        case .notifications: return "bell.badge.fill"
        case .automation: return "wand.and.stars"
        case .settings: return "gearshape.fill"
        case .support: return "heart.fill"
        }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status pill is isolated into SidebarStatus so HR/frame ticks don't re-render the whole
    // NavigationSplitView shell + sidebar list.
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem? = .today

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(NavItem.visible, selection: $selection) { item in
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .tag(item)
                }
                .listStyle(.sidebar)

                Divider().overlay(StrandPalette.hairline)
                SidebarStatus().padding(.horizontal, 14).padding(.vertical, 12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .safeAreaInset(edge: .top) { brand }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .task { await repo.refresh() }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Text("NOOP")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: TodayView()
        case .intelligence: IntelligenceView()
        case .coach: CoachView()
        case .live: LiveView()
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .appleHealth: AppleHealthView()
        case .dataSources: DataSourcesView()
        case .notifications:
            #if os(macOS)
            NotificationSettingsView()
            #else
            EmptyView()
            #endif
        case .automation:
            #if os(macOS)
            AutomationsView()
            #else
            EmptyView()
            #endif
        case .settings: SettingsView()
        case .support: SupportView()
        }
    }
}

/// Isolated live-status pill — owns the LiveState observation so the rest of RootView (sidebar
/// list + detail) does not re-render on the ~1 Hz HR / frame stream.
private struct SidebarStatus: View {
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
