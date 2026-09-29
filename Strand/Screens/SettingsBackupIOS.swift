import SwiftUI
import UniformTypeIdentifiers

// iOS backup/restore plumbing. macOS uses NSSavePanel/NSOpenPanel inside DataBackup; iOS drives the
// same core logic through SwiftUI's `.fileExporter` / `.fileImporter` (attached inside SettingsView),
// which need a `FileDocument` to hand to the exporter. Compiled out on macOS.
#if !os(macOS)

/// A wrapper around the staged `.noopbak` backup so `.fileExporter` can write it to a user-chosen
/// location (e.g. the Files app / iCloud Drive). `DataBackup.prepareExportFile` already wrote the
/// verified archive to a temp URL; this streams that file's bytes out.
struct NoopBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { DataBackup.backupContentTypes() }
    static var writableContentTypes: [UTType] { DataBackup.backupContentTypes() }

    let data: Data
    let filename: String

    init(url: URL) {
        self.data = (try? Data(contentsOf: url)) ?? Data()
        self.filename = url.lastPathComponent
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = "NOOP-backup.noopbak"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
