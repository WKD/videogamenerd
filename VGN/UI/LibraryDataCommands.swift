import AppKit
import SwiftUI
import UniformTypeIdentifiers

// File ▸ Export Library… / Restore from Backup… (PLAN §9 "Safety"). The data work lives in
// `LibraryExporter` and `AppDatabase.restore`; this file is only the menu + panels.

/// A restore chosen by the user is applied at the NEXT launch, before the database is
/// opened (the restore swaps the file, which must not happen under an open pool).
///
/// The bookkeeping (`UserDefaults`) and the on-disk locations (the live `vgn.sqlite`
/// and its `backups/` folder) are injected so the glue can be unit-tested without
/// touching the owner's real preferences or Application Support directory. Production
/// call sites use ``PendingRestore/live``.
struct PendingRestore {
    private static let pathKey = "VGNPendingRestorePath"
    private static let resultKey = "VGNLastRestoreResult"

    /// Where the "restore is pending" / "last restore result" flags live.
    var defaults: UserDefaults
    /// The Application Support folder holding `vgn.sqlite` and `backups/`.
    var supportDirectory: () throws -> URL
    /// Opens the live database for the pre-restore safety snapshot. A seam so this
    /// UI-layer type needn't import GRDB and tests can point it at a temp file; it
    /// must open the database at ``supportDirectory``/`vgn.sqlite`.
    var openLiveDatabase: () throws -> AppDatabase

    /// Production configuration: the owner's real preferences + real app-support dirs.
    static var live: PendingRestore {
        PendingRestore(
            defaults: .standard,
            supportDirectory: { try AppPaths.supportDirectory() },
            openLiveDatabase: { try AppDatabase.live() }
        )
    }

    private func databaseURL() throws -> URL {
        try supportDirectory().appendingPathComponent("vgn.sqlite")
    }

    private func backupsDirectory() throws -> URL {
        let dir = try supportDirectory().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func schedule(_ url: URL) { defaults.set(url.path, forKey: Self.pathKey) }

    /// Called first thing in live launches. Takes a safety snapshot of the current
    /// library, then restores. Never throws: a failure leaves the live database untouched
    /// (restore validates + stages before swapping) and is reported after launch. The
    /// pending flag is cleared up front, so a failing restore is attempted only once
    /// (no restore loop on every launch).
    func applyIfScheduled() {
        guard let path = defaults.string(forKey: Self.pathKey) else { return }
        defaults.removeObject(forKey: Self.pathKey)
        let source = URL(fileURLWithPath: path)
        do {
            try AppDatabase.validateBackup(at: source)
            let destination = try databaseURL()
            let backups = try backupsDirectory()
            // Safety net: snapshot what is about to be replaced, then close the pool.
            do {
                let current = try openLiveDatabase()
                _ = try current.backup(intoDirectory: backups)
                try AppDatabase.rotateBackups(inDirectory: backups, keeping: 10)
                try current.dbWriter.close()
            }
            try AppDatabase.restore(from: source, to: destination)
            defaults.set("Restored the library from \(source.lastPathComponent).", forKey: Self.resultKey)
        } catch {
            NSLog("VGN: restore from \(path) failed: \(error)")
            defaults.set("Restore failed — your library was left unchanged. (\(error.localizedDescription))",
                         forKey: Self.resultKey)
        }
    }

    /// One-shot message describing the outcome of the last restore, for a banner.
    func consumeResult() -> (message: String, failed: Bool)? {
        guard let message = defaults.string(forKey: Self.resultKey) else { return nil }
        defaults.removeObject(forKey: Self.resultKey)
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
        PendingRestore.live.schedule(url)
        NSApp.terminate(nil)
    }
}
