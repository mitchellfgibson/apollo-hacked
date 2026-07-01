import Foundation
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers
import WhoopStore

/// Full-database EXPORT / IMPORT for device migration.
///
/// NOOP keeps everything in one SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, plus the
/// `-wal`/`-shm` WAL sidecars while the store is open). Moving to another Mac is therefore just a
/// matter of moving that file. Export checkpoints the WAL (so the single file is whole) and copies
/// it to a user-chosen location; import validates a chosen backup, snapshots the current DB to a
/// side file, drops the backup in over the live path, and asks the user to relaunch (the store is
/// held open, so the new file can't be swapped in live).
///
/// Sandbox-safe: relies on the `com.apple.security.files.user-selected.read-write` entitlement and
/// security-scoped access on the panel-returned URLs. Every path is best-effort — failures surface
/// as a `.failure` result and never crash.
enum DataBackup {

    // MARK: - Result

    enum BackupResult: Error {
        /// Export wrote the backup to `url`.
        case exported(URL)
        /// Import succeeded; a relaunch is required for it to take effect. `sidecar` is where the
        /// previous database was preserved, in case the user wants to roll back.
        case imported(sidecar: URL)
        /// The user dismissed the save/open panel — nothing happened, show nothing loud.
        case cancelled
        /// Something went wrong; `message` is user-facing.
        case failure(String)
    }

    // MARK: - Export (macOS, panel-driven)

    #if os(macOS)
    /// Checkpoint (if the store is reachable) and copy the live database to a user-chosen file.
    ///
    /// - Parameter checkpoint: invoked first to flush the WAL into the main file. Pass
    ///   `repo.checkpointForBackup`; returns whether a checkpoint actually ran. When it doesn't
    ///   (store not open yet, or it failed), we copy the on-disk files as-is — including any `-wal`
    ///   sidecar — so the backup is still complete, just not consolidated.
    @MainActor
    static func runExport(checkpoint: @escaping () async -> Bool) async -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the NOOP database. \(error.localizedDescription)") }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure("There's no NOOP data to export yet. Import or record some first.")
        }

        // Flush the WAL so the single .sqlite carries everything. Best-effort.
        let checkpointed = await checkpoint()

        // Ask where to save.
        let panel = NSSavePanel()
        panel.title = "Export NOOP backup"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultBackupName()
        panel.allowedContentTypes = sqliteContentTypes()
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let dest = panel.url else { return .cancelled }

        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        do {
            // NSSavePanel already handled the "replace existing?" confirmation; clear the target.
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: dbURL, to: dest)

            // If we couldn't checkpoint, fold any pending WAL into the side copy so the backup is
            // self-contained. We can't run SQLite over the destination safely here, so instead we
            // copy the sidecars next to it under the same base name; importing copies only the main
            // file, but at least nothing is silently lost. In practice the store is almost always
            // open and the checkpoint succeeds, leaving no WAL to worry about.
            if !checkpointed {
                copySidecarsIfPresent(from: dbURL, toMainBackup: dest)
            }
            return .exported(dest)
        } catch {
            return .failure("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import (macOS, panel-driven)

    /// Pick a `.sqlite` backup, validate it, snapshot the current DB to a side file, then copy the
    /// backup over the live database path (removing the `-wal`/`-shm` siblings). The store stays
    /// open, so the swapped-in file only takes effect after a relaunch — the caller informs the user.
    @MainActor
    static func runImport() async -> BackupResult {
        let panel = NSOpenPanel()
        panel.title = "Import NOOP backup"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = sqliteContentTypes()

        guard panel.runModal() == .OK, let source = panel.url else { return .cancelled }
        return install(from: source, securityScoped: true)
    }
    #endif // os(macOS)

    // MARK: - Export / Import (iOS, SwiftUI file-picker driven)
    //
    // On iOS there are no modal panels: `.fileExporter` / `.fileImporter` are view modifiers that
    // hand the view a destination (export) or a picked source (import) URL. These two entry points
    // do the platform-independent work; the view supplies the URL.

    /// Prepare a consolidated copy of the database in a temporary directory, ready to hand to
    /// `.fileExporter`. Returns the temp URL to export, or a `.failure`/`.cancelled` reason.
    ///
    /// - Parameter checkpoint: flushes the WAL into the main file first (best-effort), same as macOS.
    @MainActor
    static func prepareExportFile(checkpoint: @escaping () async -> Bool) async -> Result<URL, BackupResult> {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure(.failure("Couldn't locate the NOOP database. \(error.localizedDescription)")) }

        let dbURL = URL(fileURLWithPath: dbPath)
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return .failure(.failure("There's no NOOP data to export yet. Import or record some first."))
        }

        _ = await checkpoint()

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(defaultBackupName())
        do {
            if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
            try fm.copyItem(at: dbURL, to: tmp)
            return .success(tmp)
        } catch {
            return .failure(.failure("Export failed: \(error.localizedDescription)"))
        }
    }

    /// Install a `.fileImporter`-picked backup over the live database. The picked URL is
    /// security-scoped on iOS, so we access it as such.
    @MainActor
    static func importPicked(_ source: URL) -> BackupResult {
        install(from: source, securityScoped: true)
    }

    // MARK: - Shared install (validate + swap in)

    /// Validate that `source` is a SQLite file, snapshot the current DB to a rollback sidecar, then
    /// copy `source` over the live database (removing WAL/SHM siblings). Used by both the macOS
    /// panel path and the iOS file-importer path.
    @MainActor
    private static func install(from source: URL, securityScoped: Bool) -> BackupResult {
        let dbPath: String
        do { dbPath = try StorePaths.defaultDatabasePath() }
        catch { return .failure("Couldn't locate the NOOP database. \(error.localizedDescription)") }

        let scoped = securityScoped && source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // Validate: must be a real SQLite database (magic header "SQLite format 3\0").
        guard isSQLiteFile(at: source) else {
            return .failure("That file isn't a NOOP backup — it doesn't look like a SQLite database.")
        }

        let fm = FileManager.default
        let dbURL = URL(fileURLWithPath: dbPath)

        do {
            // Snapshot the current DB to a timestamped side file so the user can roll back.
            var sidecar = dbURL.deletingLastPathComponent()
                .appendingPathComponent("whoop-replaced-\(timestamp()).sqlite")
            if fm.fileExists(atPath: dbURL.path) {
                if fm.fileExists(atPath: sidecar.path) { try fm.removeItem(at: sidecar) }
                try fm.copyItem(at: dbURL, to: sidecar)
            } else {
                // Nothing to preserve (fresh install); report a placeholder so the message reads sensibly.
                sidecar = dbURL
            }

            // Remove the live DB and its WAL/SHM siblings, then drop the backup in.
            removeIfPresent(dbURL)
            removeIfPresent(URL(fileURLWithPath: dbPath + "-wal"))
            removeIfPresent(URL(fileURLWithPath: dbPath + "-shm"))

            try fm.copyItem(at: source, to: dbURL)
            return .imported(sidecar: sidecar)
        } catch {
            return .failure("Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// "NOOP-backup-2026-06-07.sqlite"
    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "NOOP-backup-\(f.string(from: Date())).sqlite"
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    /// `.sqlite` UTType if the system knows it, always falling back to the generic database type so
    /// the picker still opens on systems without a `.sqlite` declaration. Used by the macOS panels
    /// and by the iOS `.fileImporter`.
    static func sqliteContentTypes() -> [UTType] {
        var types: [UTType] = []
        if let sqlite = UTType(filenameExtension: "sqlite") { types.append(sqlite) }
        types.append(.database)
        types.append(.data)
        return types
    }

    /// Read the first 16 bytes and check for the SQLite magic header.
    private static func isSQLiteFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count >= 16 else { return false }
        // "SQLite format 3" + NUL terminator.
        let magic: [UInt8] = Array("SQLite format 3".utf8) + [0x00]
        return Array(head) == magic
    }

    private static func removeIfPresent(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
    }

    #if os(macOS)
    /// Copy `<db>-wal`/`<db>-shm` next to the main backup, under the backup's base name, if they
    /// exist on disk (only reached when the checkpoint didn't run). Best-effort — failures are ignored.
    /// Only the macOS panel export path needs this (the iOS path checkpoints then copies the single file).
    private static func copySidecarsIfPresent(from dbURL: URL, toMainBackup dest: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: side.path) else { continue }
            let target = URL(fileURLWithPath: dest.path + suffix)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try? fm.copyItem(at: side, to: target)
        }
    }
    #endif // os(macOS)
}
