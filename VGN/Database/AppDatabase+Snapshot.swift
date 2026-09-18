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

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
