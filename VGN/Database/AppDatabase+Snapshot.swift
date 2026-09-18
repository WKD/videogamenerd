import Foundation
import GRDB

extension AppDatabase {
    /// Take a consistent backup copy of the whole database, keeping only the
    /// most recent `keeping` snapshots (PLAN §9 Safety).
    ///
    /// The UI lane calls ``makeLaunchSnapshot(keeping:)`` once at app start (see
    /// handoff). Uses `VACUUM INTO`, which writes a clean, defragmented copy in
    /// a single consistent read — safe against concurrent WAL writes. Returns
    /// the new snapshot's URL (nil is never returned on success).
    @discardableResult
    func makeLaunchSnapshot(keeping limit: Int = 10) throws -> URL {
        let dir = try AppPaths.backupsDirectory()
        let url = try backup(intoDirectory: dir)
        try Self.rotateBackups(inDirectory: dir, keeping: limit)
        return url
    }

    /// Write a `VACUUM INTO` snapshot into `directory`, named
    /// `vgn-<timestamp>.sqlite`. Exposed for tests (temp dir).
    @discardableResult
    func backup(intoDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: Date())
        var url = directory.appendingPathComponent("vgn-\(stamp).sqlite")
        // Guard against two snapshots within the same second.
        if FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("vgn-\(stamp)-\(UUID().uuidString.prefix(6)).sqlite")
        }
        // VACUUM cannot run inside a transaction, so bypass GRDB's implicit one.
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        return url
    }

    /// Keep only the newest `keeping` `vgn-*.sqlite` files in `directory`.
    static func rotateBackups(inDirectory directory: URL, keeping limit: Int) throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let snapshots = files
            .filter { $0.lastPathComponent.hasPrefix("vgn-") && $0.pathExtension == "sqlite" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if l == r { return lhs.lastPathComponent > rhs.lastPathComponent }
                return l > r   // newest first
            }
        guard snapshots.count > limit else { return }
        for stale in snapshots[limit...] {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - Restore

    /// A backup could not be restored.
    enum RestoreError: Error, Sendable, Equatable {
        case missing                 // the snapshot file does not exist
        case notAVGNDatabase         // the file is not a readable VGN snapshot
    }

    /// Verify `url` is a readable VGN snapshot: an openable SQLite database that
    /// carries the `games` table. Throws ``RestoreError`` otherwise. Opens the file
    /// read-only and closes it before returning, so it never mutates the snapshot.
    static func validateBackup(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw RestoreError.missing }
        var config = Configuration()
        config.readonly = true
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            let ok = try queue.read { db in
                try Bool.fetchOne(
                    db, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='games'") ?? false
            }
            guard ok else { throw RestoreError.notAVGNDatabase }
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError.notAVGNDatabase
        }
    }

    /// Restore the database file at `destination` from the snapshot at `source`
    /// (PLAN §9 Safety — "backups nobody has ever restored are not backups").
    ///
    /// **Precondition:** no `DatabasePool` / ``AppDatabase`` is open on `destination`.
    /// Call this at launch, *before* ``live()`` — it replaces the database file and
    /// deletes the WAL sidecars, which a live connection would fight. The snapshot is
    /// validated first, and staged next to the destination before the swap, so a bad
    /// or unreadable `source` leaves the existing database untouched.
    static func restore(from source: URL, to destination: URL) throws {
        try validateBackup(at: source)
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent("vgn-restore-\(UUID().uuidString).sqlite")
        try fm.copyItem(at: source, to: staged)
        do {
            // Remove the live file and any stale WAL/SHM (the snapshot is a clean,
            // non-WAL VACUUM INTO copy; a leftover -wal would corrupt it), then move
            // the validated copy into place with an atomic same-directory rename.
            for path in [destination.path, destination.path + "-wal", destination.path + "-shm"] {
                try? fm.removeItem(atPath: path)
            }
            try fm.moveItem(at: staged, to: destination)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Convenience: restore the live application database from `source` (resolves the
    /// live path via ``AppPaths``). Precondition as ``restore(from:to:)``.
    static func restoreLive(from source: URL) throws {
        try restore(from: source, to: AppPaths.databaseURL())
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
