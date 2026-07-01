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
            strapCard
            backupCard
            aboutCard
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
                FormRow(label: "Age") {
                    HStack(spacing: 12) {
                        Text("\(profile.age)")
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(minWidth: 28, alignment: .trailing)
                        Stepper("Age", value: $profile.age, in: 13...100)
                            .labelsHidden()
                            .accessibilityLabel("Age, \(profile.age) years")
                    }
                }
                rowDivider
                FormRow(label: "Sex") {
                    Picker("Sex", selection: $profile.sex) {
                        Text("Male").tag("male")
                        Text("Female").tag("female")
                        Text("Non-binary").tag("nonbinary")
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityLabel("Sex")
                }
                rowDivider
                FormRow(label: "Weight") {
                    measureField(value: $profile.weightKg, unit: "kg",
                                 range: 30...250, step: 0.5, format: "%.1f",
                                 accessibility: "Weight in kilograms")
                }
                rowDivider
                FormRow(label: "Height") {
                    measureField(value: $profile.heightCm, unit: "cm",
                                 range: 120...230, step: 1, format: "%.0f",
                                 accessibility: "Height in centimetres")
                }
                rowDivider
                FormRow(label: "Max heart rate") {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            hrMaxField
                            Text("bpm")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
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

    // MARK: - About

    private var aboutCard: some View {
        SettingsSection(
            icon: "info.circle.fill",
            title: "About",
            blurb: "NOOP — all your data, none of the cloud."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Text("NOOP")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    StatePill("v0.1.0", tone: .neutral, showsDot: false)
                }

                Text("A standalone macOS companion for your WHOOP. Everything stays on this Mac — your history, your live stream, your numbers. Nothing is uploaded.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Medical disclaimer
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 13))
                        .accessibilityHidden(true)
                    Text("NOOP is not a medical device. It is for informational and personal-insight purposes only and is not intended to diagnose, treat, cure or prevent any condition. Talk to a clinician for medical advice.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
                )

                rowDivider

                VStack(alignment: .leading, spacing: 6) {
                    Text("Built on").strandOverline()
                    attribution(repo: "johnmiddleton12/my-whoop", note: "WHOOP 4.0 protocol")
                    attribution(repo: "b-nnett/goose", note: "WHOOP 5.0 protocol")
                }

                Text("Open-source BLE reverse-engineering work. Thank you.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func attribution(repo: String, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .accessibilityHidden(true)
            Text(repo)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textPrimary)
            Text("· \(note)")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
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
        .preferredColorScheme(.dark)
}
#endif
