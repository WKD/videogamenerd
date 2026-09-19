import AppKit
import SwiftUI
import UniformTypeIdentifiers

// File ▸ Export Library… / Restore from Backup… (PLAN §9 "Safety"). The data work lives in
// `LibraryExporter` and `AppDatabase.restore`; this file is only the menu + panels.

/// A restore chosen by the user is applied at the NEXT launch, before the database is
/// opened (the restore swaps the file, which must not happen under an open pool).
enum PendingRestore {
    private static let pathKey = "VGNPendingRestorePath"
    private static let resultKey = "VGNLastRestoreResult"

    static func schedule(_ url: URL) { UserDefaults.standard.set(url.path, forKey: pathKey) }

    /// Called first thing in live launches. Takes a safety snapshot of the current
    /// library, then restores. Never throws: a failure leaves the live database untouched
    /// (restore validates + stages before swapping) and is reported after launch.
    static func applyIfScheduled() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: pathKey) else { return }
        defaults.removeObject(forKey: pathKey)
        let source = URL(fileURLWithPath: path)
        do {
            try AppDatabase.validateBackup(at: source)
            // Safety net: snapshot what is about to be replaced, then close the pool.
            do {
                let current = try AppDatabase.live()
                _ = try current.makeLaunchSnapshot()
                try current.dbWriter.close()
            }
            try AppDatabase.restoreLive(from: source)
            defaults.set("Restored the library from \(source.lastPathComponent).", forKey: resultKey)
        } catch {
            NSLog("VGN: restore from \(path) failed: \(error)")
            defaults.set("Restore failed — your library was left unchanged. (\(error.localizedDescription))",
                         forKey: resultKey)
        }
    }

    /// One-shot message describing the outcome of the last restore, for a banner.
    static func consumeResult() -> (message: String, failed: Bool)? {
        let defaults = UserDefaults.standard
        guard let message = defaults.string(forKey: resultKey) else { return nil }
        defaults.removeObject(forKey: resultKey)
        return (message, message.hasPrefix("Restore failed"))
    }
}

struct LibraryDataCommands: Commands {
    let database: AppDatabase?
    let library: LibraryViewModel?

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Export Library as JSON…") { export(json: true) }
                .disabled(database == nil)
            Button("Export Library as CSV…") { export(json: false) }
                .disabled(database == nil)
            Divider()
            Button("Restore from Backup…") { chooseBackup() }
                .disabled(database == nil)
            Button("Show Backups in Finder") {
                if let dir = try? AppPaths.backupsDirectory() { NSWorkspace.shared.open(dir) }
            }
        }
    }

    private func export(json: Bool) {
        guard let database else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [json ? .json : .commaSeparatedText]
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "VGN library \(stamp).\(json ? "json" : "csv")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let exporter = LibraryExporter(database)
                if json {
                    try await exporter.exportJSON().write(to: url, options: .atomic)
                } else {
                    // UTF-8 BOM so Excel opens accented titles correctly.
                    let csv = try await exporter.exportCSV()
                    try (Data([0xEF, 0xBB, 0xBF]) + Data(csv.utf8)).write(to: url, options: .atomic)
                }
                library?.showBanner("Exported the library to \(url.lastPathComponent).")
            } catch {
                library?.showBanner("Export failed: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        panel.directoryURL = try? AppPaths.backupsDirectory()
        panel.message = "Choose a backup to restore. VGN keeps the last 10 launch snapshots."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try AppDatabase.validateBackup(at: url) } catch {
            library?.showBanner("That file is not a usable VGN backup.", kind: .error)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace your library with \(url.lastPathComponent)?"
        alert.informativeText = "Everything added or ranked since that backup will be replaced. "
            + "VGN first saves a snapshot of the current library to the Backups folder, then restores when it next opens."
        alert.addButton(withTitle: "Restore and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PendingRestore.schedule(url)
        NSApp.terminate(nil)
    }
}
