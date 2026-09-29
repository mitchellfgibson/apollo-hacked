import Foundation

// iOS backup/restore entry points (fork-local).
//
// macOS drives export/import through NSSavePanel / NSOpenPanel inside `DataBackup`. iOS has no modal
// panels: `.fileExporter` / `.fileImporter` are view modifiers that hand the view a destination or a
// picked source URL. These two entry points do the platform-independent half; the view supplies the
// URL. Upstream's own iOS app uses a different settings screen, so this seam is ours.
#if !os(macOS)

// `Result<URL, BackupResult>` below needs its failure type to be an `Error`. `BackupResult` is a
// plain outcome enum upstream (it is switched over, never thrown), so the conformance is declared
// here rather than on the type — nothing throws it, and macOS never sees this file.
extension DataBackup.BackupResult: @retroactive Error {}

extension DataBackup {

    /// Stage a `.noopbak` in the temporary directory, ready to hand to `.fileExporter`.
    ///
    /// Writes through `writeBackup(checkpoint:to:)` — the same verified ZIP path the macOS panel
    /// uses — rather than copying the raw SQLite, so an iOS-made backup carries the manifest and
    /// settings sidecar and restores on either platform.
    ///
    /// - Parameter checkpoint: flushes the WAL into the main file first (best-effort), as on macOS.
    @MainActor
    static func prepareExportFile(checkpoint: @escaping () async -> Bool) async -> Result<URL, BackupResult> {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(defaultBackupName())
        try? FileManager.default.removeItem(at: tmp)

        let outcome = await writeBackup(checkpoint: checkpoint, to: tmp)
        switch outcome {
        case .exported(let url):
            return .success(url)
        case .exportedOversize(let url, _, _):
            // The archive is complete and worth keeping — only RESTORING it needs a confirmation.
            // Handing it to the exporter is right; the size warning belongs to the import side.
            return .success(url)
        default:
            return .failure(outcome)
        }
    }

    /// Install a `.fileImporter`-picked backup over the live database. `restore(from:)` already
    /// handles the security-scoped access the picked URL arrives with.
    @MainActor
    static func importPicked(_ source: URL) -> BackupResult {
        restore(from: source)
    }
}

#endif
