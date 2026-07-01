import SwiftUI
import UniformTypeIdentifiers

// iOS backup/restore plumbing. macOS uses NSSavePanel/NSOpenPanel inside DataBackup; iOS drives the
// same core logic through SwiftUI's `.fileExporter` / `.fileImporter` (attached inside SettingsView),
// which need a `FileDocument` to hand to the exporter. Compiled out on macOS.
#if !os(macOS)

/// A wrapper around the prepared SQLite backup file so `.fileExporter` can write it to a user-chosen
/// location (e.g. the Files app / iCloud Drive). We already copied the live DB to a temp URL in
/// `DataBackup.prepareExportFile`; this streams that file's bytes out.
struct SQLiteBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { DataBackup.sqliteContentTypes() }
    static var writableContentTypes: [UTType] { DataBackup.sqliteContentTypes() }

    let data: Data
    let filename: String

    init(url: URL) {
        self.data = (try? Data(contentsOf: url)) ?? Data()
        self.filename = url.lastPathComponent
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        filename = "NOOP-backup.sqlite"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
