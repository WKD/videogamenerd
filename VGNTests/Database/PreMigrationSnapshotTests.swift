import Foundation
import GRDB
import Testing
@testable import VGN

/// An existing library is copied aside before a pending migration touches it.
@Suite(.serialized)
struct PreMigrationSnapshotTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VGN-premig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pool(in dir: URL) throws -> DatabasePool {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try DatabasePool(path: dir.appendingPathComponent("vgn.sqlite").path, configuration: config)
    }

    /// The migrator as it was before v5 existed.
    private var migratorUpToV4: DatabaseMigrator {
        var m = DatabaseMigrator()
        Migrations.registerV1(in: &m)
        Migrations.registerV2(in: &m)
        Migrations.registerV3(in: &m)
        Migrations.registerV4(in: &m)
        return m
    }

    @Test func brandNewDatabaseIsNotSnapshotted() throws {
        let dir = try tempDir()
        let url = try AppDatabase.snapshotBeforePendingMigrations(try pool(in: dir), into: dir.appendingPathComponent("backups"))
        #expect(url == nil)
    }

    @Test func upToDateDatabaseIsNotSnapshotted() throws {
        let dir = try tempDir()
        let pool = try pool(in: dir)
        try AppDatabase.migrator.migrate(pool)
        let url = try AppDatabase.snapshotBeforePendingMigrations(pool, into: dir.appendingPathComponent("backups"))
        #expect(url == nil)
    }

    @Test func pendingMigrationSnapshotsTheOldLibraryFirst() throws {
        let dir = try tempDir()
        let pool = try pool(in: dir)
        try migratorUpToV4.migrate(pool)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO games (title, sort_title, played) VALUES ('Bloodborne', 'bloodborne', 1)")
        }
        let backups = dir.appendingPathComponent("backups")
        let url = try #require(try AppDatabase.snapshotBeforePendingMigrations(pool, into: backups))
        #expect(url.lastPathComponent.hasPrefix("premigration-v5-"))
        // Not matched by the launch-snapshot rotation (`vgn-*.sqlite`).
        #expect(!url.lastPathComponent.hasPrefix("vgn-"))

        // The copy is the pre-v5 library: the game is there, v5 is not applied.
        let copy = try DatabaseQueue(path: url.path)
        let (titles, applied) = try copy.read { db in
            (try String.fetchAll(db, sql: "SELECT title FROM games"),
             try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"))
        }
        #expect(titles == ["Bloodborne"])
        #expect(applied == ["v1", "v2", "v3", "v4"])

        // Migrating afterwards keeps the data.
        try AppDatabase.migrator.migrate(pool)
        let after = try pool.read { db in try String.fetchAll(db, sql: "SELECT title FROM games") }
        #expect(after == ["Bloodborne"])
    }

    @Test func theMigratorNeverErasesOnSchemaChange() {
        #expect(AppDatabase.migrator.eraseDatabaseOnSchemaChange == false)
    }
}
