import SwiftUI
import StrandDesign
import WhoopStore
import UniformTypeIdentifiers

/// Settings — profile (powers zones / calories / recovery), strap connection, and about.
/// Grouped cards on surface.raised with a two-column form feel.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var profile: ProfileStore

    /// Profile is locked (read-only) by default; the user taps Edit to change their numbers.
    @State private var editingProfile = false

    /// Include imported 2024/2025 history (past) alongside present data. OFF = present only
    /// (from the June 10 2026 boundary onward). Applied app-wide in Repository.refresh().
    @AppStorage(HistoryFilter.includePastKey) private var includePastData = true

    /// Backup & restore UI state.
    @State private var backupBusy = false
    @State private var backupAlertTitle = ""
    @State private var backupAlertMessage = ""
    @State private var showBackupAlert = false

    #if !os(macOS)
    // iOS drives backup through SwiftUI file pickers (there are no modal panels). The exporter needs
    // a prepared document; the importer hands back a picked URL.
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var exportDocument: SQLiteBackupDocument?
    #endif

    var body: some View {
        ScreenScaffold(title: "Settings",
                       subtitle: "Your numbers, your strap, and how NOOP works. All on this device.") {
            profileCard
            sleepDataCard
            strapCard
            // The old "Data" nav page now lives here — embedded (no scaffold), with env + state intact.
            DataSourcesView(embedded: true)
            backupCard

            // Simple version footer (replaces the old About page).
            Text("Version 1")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .alert(backupAlertTitle, isPresented: $showBackupAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(backupAlertMessage)
        }
        .modify { content in
            #if os(macOS)
            content
            #else
            content
                .fileExporter(isPresented: $showExporter,
                              document: exportDocument,
                              contentType: .database,
                              defaultFilename: exportDocument?.filename ?? "NOOP-backup.sqlite") { result in
                    finishExport(result)
                }
                .fileImporter(isPresented: $showImporter,
                              allowedContentTypes: DataBackup.sqliteContentTypes(),
                              allowsMultipleSelection: false) { result in
                    finishImport(result)
                }
            #endif
        }
    }

    #if !os(macOS)
    @MainActor private func finishExport(_ result: Result<URL, Error>) {
        backupBusy = false
        switch result {
        case .success:
            backupAlertTitle = "Backup exported"
            backupAlertMessage = "Saved. Copy this file to your other device and use Import there to restore everything."
            showBackupAlert = true
        case .failure(let error):
            // A user cancel arrives as a failure with a userCancelled code — treat it as a no-op.
            if (error as NSError).code == NSUserCancelledError { return }
            handleBackup(.failure("Export failed: \(error.localizedDescription)"))
        }
    }

    @MainActor private func finishImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            backupBusy = true
            handleBackup(DataBackup.importPicked(url))
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            handleBackup(.failure("Import failed: \(error.localizedDescription)"))
        }
    }
    #endif

    // MARK: - Profile

    private var profileCard: some View {
        SettingsSection(
            icon: "person.fill",
            title: "Profile",
            blurb: "These power your heart-rate zones, calorie estimates and recovery baselines. Keep them accurate."
        ) {
            VStack(spacing: 0) {
                // Edit / Done toggle — the whole card is read-only until the user opts in.
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editingProfile.toggle() }
                    } label: {
                        Label(editingProfile ? "Done" : "Edit",
                              systemImage: editingProfile ? "checkmark" : "pencil")
                            .font(StrandFont.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                    .accessibilityLabel(editingProfile ? "Done editing profile" : "Edit profile")
                }
                .padding(.bottom, 4)

                FormRow(label: "Age") {
                    if editingProfile {
                        HStack(spacing: 12) {
                            Text("\(profile.age)")
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(minWidth: 28, alignment: .trailing)
                            Stepper("Age", value: $profile.age, in: 13...100)
                                .labelsHidden()
                                .accessibilityLabel("Age, \(profile.age) years")
                        }
                    } else {
                        readOnlyValue("\(profile.age)", unit: "yrs")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    if editingProfile {
                        Picker("Sex", selection: $profile.sex) {
                            Text("Male").tag("male")
                            Text("Female").tag("female")
                            Text("Non-binary").tag("nonbinary")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityLabel("Sex")
                    } else {
                        readOnlyValue(sexLabel(profile.sex))
                    }
                }
                rowDivider
                FormRow(label: "Weight") {
                    if editingProfile {
                        measureField(value: $profile.weightKg, unit: "kg",
                                     range: 30...250, step: 0.5, format: "%.1f",
                                     accessibility: "Weight in kilograms")
                    } else {
                        readOnlyValue(String(format: "%.1f", profile.weightKg), unit: "kg")
                    }
                }
                rowDivider
                FormRow(label: "Height") {
                    if editingProfile {
                        measureField(value: $profile.heightCm, unit: "cm",
                                     range: 120...230, step: 1, format: "%.0f",
                                     accessibility: "Height in centimetres")
                    } else {
                        readOnlyValue(String(format: "%.0f", profile.heightCm), unit: "cm")
                    }
                }
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        if editingProfile {
                            HStack(spacing: 8) {
                                hrMaxField
                                Text("bpm")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        } else {
                            readOnlyValue(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "\(profile.hrMax)",
                                          unit: "bpm")
                        }
                        Text(profile.hrMaxOverride > 0
                             ? "Manual override"
                             : "Auto · \(profile.hrMax) bpm (Tanaka)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(profile.hrMaxOverride > 0
                                             ? StrandPalette.accent
                                             : StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    /// A locked, read-only profile value: tabular number + optional unit, no controls.
    private func readOnlyValue(_ text: String, unit: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
            if let unit {
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Human label for the stored sex tag.
    private func sexLabel(_ tag: String) -> String {
        switch tag {
        case "male": return "Male"
        case "female": return "Female"
        case "nonbinary": return "Non-binary"
        default: return tag.capitalized
        }
    }

    /// Numeric weight/height field: tabular value + small +/- stepper.
    private func measureField(value: Binding<Double>, unit: String,
                              range: ClosedRange<Double>, step: Double,
                              format: String, accessibility: String) -> some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: format, value.wrappedValue))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 48, alignment: .trailing)
                Text(unit)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Stepper(accessibility, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(accessibility)
        }
    }

    /// HR-max override: 0 = auto. Shown as a compact tabular value with a stepper.
    private var hrMaxField: some View {
        HStack(spacing: 10) {
            Text(profile.hrMaxOverride > 0 ? "\(profile.hrMaxOverride)" : "Auto")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(profile.hrMaxOverride > 0
                                 ? StrandPalette.textPrimary
                                 : StrandPalette.textTertiary)
                .frame(minWidth: 44, alignment: .trailing)
            Stepper("Max heart rate override",
                    value: $profile.hrMaxOverride, in: 0...230, step: 1)
                .labelsHidden()
                .accessibilityLabel("Max heart rate override, \(profile.hrMaxOverride == 0 ? "automatic" : "\(profile.hrMaxOverride) bpm")")
        }
    }

    // MARK: - History (past / present data)

    /// The app-wide past/present filter. ON = your imported 2024/2025 history is shown alongside
    /// present data; OFF = present only (from the June 10 2026 boundary onward). Flipping it
    /// re-filters every screen by reloading the repository.
    private var sleepDataCard: some View {
        SettingsSection(
            icon: "clock.arrow.circlepath",
            title: "History",
            blurb: "Include your imported history from before \(HistoryFilter.cutoverLabel), or show only present data from then on. Applies everywhere — Today, Trends, Sleep and more."
        ) {
            VStack(spacing: 0) {
                FormRow(label: "Include past data") {
                    Toggle("", isOn: $includePastData)
                        .labelsHidden()
                        .tint(StrandPalette.accent)
                        .accessibilityLabel("Include past data before \(HistoryFilter.cutoverLabel)")
                        .onChange(of: includePastData) { _ in
                            // Re-filter the whole app immediately.
                            Task { await model.repo.refresh() }
                        }
                }
                rowDivider
                FormRow(label: "Showing") {
                    readOnlyValue(includePastData ? "Past + present" : "Present only")
                }
                rowDivider
                FormRow(label: "Present starts") {
                    readOnlyValue(HistoryFilter.cutoverLabel)
                }
            }
        }
    }

    // MARK: - Strap

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Strap",
            blurb: "NOOP pairs directly with your WHOOP over Bluetooth — no WHOOP app, no cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatePill(strapStatusTitle, tone: strapTone, pulsing: live.connected)
                    if let pct = live.batteryPct {
                        StatePill("Battery \(Int(pct.rounded()))%",
                                  tone: batteryTone(pct), showsDot: false)
                    }
                    Spacer(minLength: 0)
                    // Data-sync circle: slowly fills as we catch up on the strap's stored history.
                    // Full = "live" (caught up).
                    VStack(spacing: 3) {
                        SyncRing(progress: live.syncProgress, size: 40)
                        Text(live.isLive ? "Live" : "Syncing")
                            .font(StrandFont.caption)
                            .foregroundStyle(live.isLive ? StrandPalette.accent : StrandPalette.textTertiary)
                    }
                }
                Text(strapStatusDetail)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: 12) {
                    Button {
                        model.scan()
                    } label: {
                        Label("Re-scan", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)

                    Button {
                        model.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.statusCritical)
                    .disabled(!live.connected && !live.bonded)
                }
            }
        }
    }

    private var strapStatusTitle: String {
        if live.bonded && live.connected { return "Bonded · streaming" }
        if live.connected { return "Connected" }
        if live.bonded { return "Bonded · idle" }
        return "Disconnected"
    }

    private var strapTone: StrandTone {
        if live.connected { return .positive }
        if live.bonded { return .warning }
        return .critical
    }

    private var strapStatusDetail: String {
        if live.bonded && live.connected {
            return "Your strap is paired and sending data. Open Live for a real-time heart rate."
        }
        if live.connected { return "Connected. Finishing the secure pairing handshake…" }
        if live.bonded { return "Previously paired but not currently connected. Re-scan to reconnect." }
        return "No strap connected. Put your WHOOP nearby and tap Re-scan to pair."
    }

    private func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: - Backup & restore

    private var backupCard: some View {
        SettingsSection(
            icon: "externaldrive.fill",
            title: "Backup & restore",
            blurb: "Move all your NOOP data to another machine. Export saves everything — history, sleeps, workouts, settings — to a single file you can copy across; import replaces this Mac's data with a backup."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Button {
                        runExport()
                    } label: {
                        Label("Export…", systemImage: "square.and.arrow.up")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    Button {
                        runImport()
                    } label: {
                        Label("Import…", systemImage: "square.and.arrow.down")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                    .disabled(backupBusy)

                    if backupBusy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("Importing overwrites everything currently on this Mac. Your old data is kept in a side file just in case. NOOP needs a relaunch for an import to take effect.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runExport() {
        backupBusy = true
        #if os(macOS)
        Task {
            let result = await DataBackup.runExport(checkpoint: { await model.repo.checkpointForBackup() })
            handleBackup(result)
        }
        #else
        // Prepare a consolidated file, then present `.fileExporter` (attached below).
        Task {
            switch await DataBackup.prepareExportFile(checkpoint: { await model.repo.checkpointForBackup() }) {
            case .success(let url):
                exportDocument = SQLiteBackupDocument(url: url)
                showExporter = true
            case .failure(let result):
                handleBackup(result)
            }
        }
        #endif
    }

    private func runImport() {
        #if os(macOS)
        backupBusy = true
        Task {
            let result = await DataBackup.runImport()
            handleBackup(result)
        }
        #else
        // Present `.fileImporter` (attached below); it stays un-busy until a file is chosen.
        showImporter = true
        #endif
    }

    @MainActor
    private func handleBackup(_ result: DataBackup.BackupResult) {
        backupBusy = false
        switch result {
        case .cancelled:
            return
        case .exported(let url):
            backupAlertTitle = "Backup exported"
            backupAlertMessage = "Saved to \(url.lastPathComponent). Copy this file to your other Mac and use Import there to restore everything."
            showBackupAlert = true
        case .imported:
            backupAlertTitle = "Backup imported"
            backupAlertMessage = "Your data has been restored. Quit and reopen NOOP for it to take effect."
            showBackupAlert = true
        case .failure(let message):
            backupAlertTitle = "Backup problem"
            backupAlertMessage = message
            showBackupAlert = true
        }
    }

    // MARK: - Shared bits

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}

// MARK: - Section card

/// A grouped settings card: icon + title header, an explanatory blurb, then content.
private struct SettingsSection<Content: View>: View {
    let icon: String
    let title: String
    let blurb: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(blurb)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }
}

// MARK: - Two-column form row

/// Label on the left, control on the right — the two-column form feel.
private struct FormRow<Control: View>: View {
    let label: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .frame(minHeight: 32)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Settings") {
    let model = AppModel()
    model.live.bonded = true
    model.live.connected = true
    model.live.batteryPct = 64
    return SettingsView()
        .environmentObject(model)
        .environmentObject(model.live)
        .environmentObject(model.profile)
        .frame(width: 720, height: 900)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.light)
}
#endif
