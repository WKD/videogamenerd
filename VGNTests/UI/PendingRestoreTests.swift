import Foundation
import GRDB
import Testing
@testable import VGN

/// Unit tests for `PendingRestore` — the glue that applies a chosen backup at the next
/// launch, after taking a safety snapshot of the current library (PLAN §9 Safety).
///
/// Everything is injected (an isolated `UserDefaults` suite + a throwaway temp folder
/// standing in for Application Support), so nothing touches the owner's real preferences
/// or `~/Library/Application Support/VGN/`. The database work runs on real on-disk GRDB
/// pools in the temp folder, so these tests exercise the actual snapshot + restore path.
@Suite struct PendingRestoreTests {
    private static let pathKey = "VGNPendingRestorePath"
    private static let resultKey = "VGNLastRestoreResult"

    // MARK: - Harness

    /// A throwaway Application Support layout: a temp dir that will hold `vgn.sqlite`
    /// and `backups/`, plus an isolated `UserDefaults` suite.
    private struct Harness {
        let dir: URL
        let liveURL: URL
        let defaults: UserDefaults
        let suiteName: String

        var restore: PendingRestore {
            PendingRestore(
                defaults: defaults,
                supportDirectory: { dir },
                openLiveDatabase: { try Self.openPool(at: liveURL) }
            )
        }

        static func openPool(at url: URL) throws -> AppDatabase {
            var config = Configuration()
            config.foreignKeysEnabled = true
            return try AppDatabase(try DatabasePool(path: url.path, configuration: config))
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func makeHarness() throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VGN-pending-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "pendingrestore.test.\(UUID().uuidString)"
        return Harness(
            dir: dir,
            liveURL: dir.appendingPathComponent("vgn.sqlite"),
            defaults: UserDefaults(suiteName: suite)!,
            suiteName: suite
        )
    }

    // MARK: - Database helpers

    /// Seed a closed on-disk VGN database at `url` with one game per title.
    private static func seedDatabase(at url: URL, titles: [String]) async throws {
        let db = try Harness.openPool(at: url)
        let store = LibraryStore(db)
        _ = try await db.seedPlatforms(from: TestDB.platforms)
        for title in titles {
            _ = try await store.addGame(GameDraft(title: title, platformIDs: ["pc"], owned: true))
        }
        try db.dbWriter.close()
    }

    /// A clean `VACUUM INTO` snapshot (exactly what the app's own launch snapshots are)
    /// seeded with `titles`, written under `dir`. Returns its URL.
    private static func makeBackupSnapshot(titles: [String], in dir: URL) async throws -> URL {
        let seedURL = dir.appendingPathComponent("seed-\(UUID().uuidString).sqlite")
        let db = try Harness.openPool(at: seedURL)
        let store = LibraryStore(db)
        _ = try await db.seedPlatforms(from: TestDB.platforms)
        for title in titles {
            _ = try await store.addGame(GameDraft(title: title, platformIDs: ["pc"], owned: true))
        }
        let snapshot = try db.backup(intoDirectory: dir.appendingPathComponent("src-\(UUID().uuidString)"))
        try db.dbWriter.close()
        return snapshot
    }

    /// Titles in the (closed) database at `url`, sorted. Opens a fresh single
    /// connection (no other connection is open on the file at read time).
    private static func titles(at url: URL) async throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT title FROM games ORDER BY title")
        }
    }

    /// The safety-snapshot files the app leaves in `dir/backups/`.
    private static func snapshotFiles(in dir: URL) -> [URL] {
        let backups = dir.appendingPathComponent("backups", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: backups, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("vgn-") && $0.pathExtension == "sqlite" }
    }

    // MARK: - Tests

    @Test("schedule → apply replaces the DB and leaves a safety snapshot")
    func scheduledApplyReplacesLibraryAndKeepsSafetySnapshot() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        try await Self.seedDatabase(at: h.liveURL, titles: ["Live Game"])
        let backup = try await Self.makeBackupSnapshot(titles: ["Backup Game"], in: h.dir)

        h.restore.schedule(backup)
        #expect(h.defaults.string(forKey: Self.pathKey) == backup.path)

        h.restore.applyIfScheduled()

        // The live library now holds the backup's contents.
        #expect(try await Self.titles(at: h.liveURL) == ["Backup Game"])

        // A safety snapshot of the pre-restore library was left behind, and it holds
        // exactly what the library contained before the restore.
        let snaps = Self.snapshotFiles(in: h.dir)
        #expect(snaps.count == 1)
        if let safety = snaps.first {
            #expect(try await Self.titles(at: safety) == ["Live Game"])
        }

        // Success is reported once, and the pending flag is cleared.
        #expect(h.defaults.string(forKey: Self.pathKey) == nil)
        let outcome = h.restore.consumeResult()
        #expect(outcome?.failed == false)
        #expect(outcome?.message.contains(backup.lastPathComponent) == true)
        #expect(h.restore.consumeResult() == nil)   // one-shot
    }

    @Test("apply with nothing scheduled is a no-op")
    func applyWithNothingScheduledIsNoOp() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        try await Self.seedDatabase(at: h.liveURL, titles: ["Untouched"])

        h.restore.applyIfScheduled()

        // No snapshot taken, no result recorded, the library is unchanged.
        #expect(Self.snapshotFiles(in: h.dir).isEmpty)
        #expect(h.restore.consumeResult() == nil)
        #expect(try await Self.titles(at: h.liveURL) == ["Untouched"])
    }

    @Test("a missing backup leaves the live DB untouched and reports failure")
    func missingBackupLeavesLibraryUntouchedAndReportsFailure() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        try await Self.seedDatabase(at: h.liveURL, titles: ["Keep Me"])
        let missing = h.dir.appendingPathComponent("does-not-exist.sqlite")

        h.restore.schedule(missing)
        h.restore.applyIfScheduled()

        // Live library is unchanged and no safety snapshot was written.
        #expect(try await Self.titles(at: h.liveURL) == ["Keep Me"])
        #expect(Self.snapshotFiles(in: h.dir).isEmpty)

        // Failure is reported, and the schedule was cleared (see the loop test).
        let outcome = h.restore.consumeResult()
        #expect(outcome?.failed == true)
        #expect(h.defaults.string(forKey: Self.pathKey) == nil)
    }

    @Test("a corrupt backup leaves the live DB untouched and reports failure")
    func corruptBackupLeavesLibraryUntouchedAndReportsFailure() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        try await Self.seedDatabase(at: h.liveURL, titles: ["Keep Me"])
        let junk = h.dir.appendingPathComponent("junk.sqlite")
        try Data("not a database".utf8).write(to: junk)

        h.restore.schedule(junk)
        h.restore.applyIfScheduled()

        #expect(try await Self.titles(at: h.liveURL) == ["Keep Me"])
        #expect(Self.snapshotFiles(in: h.dir).isEmpty)
        let outcome = h.restore.consumeResult()
        #expect(outcome?.failed == true)
    }

    @Test("a failing restore is attempted only once — no loop on every launch")
    func failingRestoreIsClearedAfterOneAttempt() async throws {
        let h = try Self.makeHarness()
        defer { h.cleanup() }

        try await Self.seedDatabase(at: h.liveURL, titles: ["Keep Me"])
        let missing = h.dir.appendingPathComponent("nope.sqlite")

        h.restore.schedule(missing)
        h.restore.applyIfScheduled()
        #expect(h.defaults.string(forKey: Self.pathKey) == nil)   // cleared on first attempt

        // A second launch must NOT retry: nothing is scheduled, so it is a no-op and
        // records no new result.
        _ = h.restore.consumeResult()   // drain the first failure banner
        h.restore.applyIfScheduled()
        #expect(h.restore.consumeResult() == nil)
        #expect(try await Self.titles(at: h.liveURL) == ["Keep Me"])
    }
}
