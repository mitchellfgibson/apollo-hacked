import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState
    @State private var picking = false
    @State private var pickingApple = false

    /// When true, render only the importer cards (no screen scaffold) — used to embed this inside
    /// the Settings screen, where the surrounding scaffold already exists.
    var embedded = false

    var body: some View {
        if embedded {
            VStack(spacing: 16) { sourceCards }
        } else {
            ScreenScaffold(title: "Data Sources",
                           subtitle: "Everything stays on this Mac. Bring your history in once, then it's yours.") {
                sourceCards
            }
        }
    }

    /// The importer cards WITHOUT the screen scaffold — so this content can be embedded inside the
    /// Settings "Data" section as well as shown on its own (if the standalone page is ever restored).
    @ViewBuilder var sourceCards: some View {
        // Each importer lives on its OWN card. Two `.fileImporter` modifiers on the
        // same view silently collapse to one in SwiftUI — which is why the WHOOP
        // button used to do nothing while Apple Health worked (issue #5).
        whoopCard
            .fileImporter(isPresented: $picking,
                          allowedContentTypes: [.zip, .folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importWhoop(url: url)
                }
            }
        appleHealthCard
            .fileImporter(isPresented: $pickingApple,
                          allowedContentTypes: [.zip, .folder],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.importAppleHealth(url: url)
                }
            }
        liveCard
    }

    private var whoopCard: some View {
        card(title: "WHOOP Export", icon: "square.and.arrow.down.fill",
             subtitle: "Import your full WHOOP history — recovery, strain, sleep, workouts — from a data export (.zip). Works for WHOOP 5.0 and MG. Get one at app.whoop.com → Data Management.") {
            HStack(spacing: 12) {
                Button {
                    picking = true
                } label: {
                    Label(model.importing ? "Importing…" : "Choose export…",
                          systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .disabled(model.importing)
                if model.importing { ProgressView().controlSize(.small) }
            }
            if let s = model.importSummary {
                Text(s).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
            }
            Text("\(repo.days.count) days · \(repo.sleeps.count) sleeps stored")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var appleHealthCard: some View {
        card(title: "Apple Health", icon: "heart.fill",
             subtitle: "Import an Apple Health export (Health app → profile → Export All Health Data → export.zip). 7 years of HR, HRV, sleep, SpO₂, steps and more — streamed locally. Large exports take a minute or two.") {
            HStack(spacing: 12) {
                Button { pickingApple = true } label: {
                    Label(model.importing ? "Working…" : "Choose export.zip…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.importing)
                if model.importing { ProgressView().controlSize(.small) }
            }
        }
    }

    private var liveCard: some View {
        card(title: "WHOOP Strap (Live BLE)", icon: "antenna.radiowaves.left.and.right",
             subtitle: "Pairs directly with your strap over Bluetooth — no WHOOP app, no cloud.") {
            HStack(spacing: 8) {
                Circle().fill(live.bonded ? StrandPalette.statusPositive : StrandPalette.statusCritical)
                    .frame(width: 8, height: 8)
                Text(live.bonded ? "Bonded — streaming." : "Not connected — open Live to pair.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func card<C: View>(title: String, icon: String, subtitle: String,
                              @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
    }
}
