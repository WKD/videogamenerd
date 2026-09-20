import Foundation
import GRDB

/// The single entry point to VGN's SQLite store.
///
/// Wraps a GRDB `DatabaseWriter` (a `DatabasePool` in WAL mode for the running
/// app, a `DatabaseQueue` for tests and SwiftUI previews). `Sendable`, so it can
/// be shared across actors and `@MainActor` stores; every read and write funnels
/// through GRDB's own internal synchronisation.
///
/// Construction runs migration v1 (the entire PLAN §4 schema, plus the
/// enrichment queue and ranking-session store) and seeds the tiers. Platforms
/// are (re)seeded from the bundled `platforms.json` on every launch by calling
/// ``seedPlatforms(from:)`` — the app does this at start-up; tests seed
/// explicitly.
struct AppDatabase: Sendable {
    /// GRDB's writer. Exposed for the read/observation helpers; all schema
    /// mutation still goes through ``LibraryStore``.
    let dbWriter: any DatabaseWriter

    /// Designated initialiser. `writer` is already-open; migration + tier seed
    /// run here so every code path (app, tests, previews) gets the same schema.
    init(_ writer: any DatabaseWriter) throws {
        self.dbWriter = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - Factories

    /// The real, on-disk application database at
    /// `~/Library/Application Support/VGN/vgn.sqlite` (WAL, foreign keys on).
    static func live() throws -> AppDatabase {
        let url = try AppPaths.databaseURL()
        var config = Configuration()
        config.label = "VGN.sqlite"
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        // Data safety: an existing library is snapshotted BEFORE any pending migration
        // touches it (the rotating launch snapshot only runs after migrating). A failed
        // snapshot aborts the launch rather than migrating without a way back.
        try Self.snapshotBeforePendingMigrations(pool, into: AppPaths.backupsDirectory())
        let db = try AppDatabase(pool)
        return db
    }

    /// If `writer` holds an already-migrated library with migrations still pending,
    /// write a `VACUUM INTO` copy named `premigration-<first pending>-<timestamp>.sqlite`
    /// into `directory` and return its URL. Returns nil for a brand-new database or when
    /// nothing is pending. These files do not match the `vgn-*.sqlite` rotation pattern,
    /// so they are never rotated away.
    @discardableResult
    static func snapshotBeforePendingMigrations(
        _ writer: any DatabaseWriter,
        into directory: @autoclosure () throws -> URL,
        migrator: DatabaseMigrator = AppDatabase.migrator
    ) throws -> URL? {
        let applied = try writer.read { db in try migrator.appliedIdentifiers(db) }
        guard !applied.isEmpty else { return nil }                      // brand-new store
        guard let firstPending = migrator.migrations.first(where: { !applied.contains($0) }) else {
            return nil                                                  // up to date
        }
        let dir = try directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: Date())
        var url = dir.appendingPathComponent("premigration-\(firstPending)-\(stamp).sqlite")
        if FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("premigration-\(firstPending)-\(stamp)-\(UUID().uuidString.prefix(6)).sqlite")
        }
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
        return url
    }

    /// A fresh in-memory database (a `DatabaseQueue`). For tests and previews —
    /// never touches the real file. Each call is an isolated, empty library.
    static func inMemory() throws -> AppDatabase {
        var config = Configuration()
        config.label = "VGN.memory"
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        return try AppDatabase(queue)
    }

    /// A temporary on-disk `DatabasePool` in a unique temp directory. Used by
    /// tests that need real files (e.g. the launch-snapshot / VACUUM INTO path,
    /// which requires an actual database file). Caller owns the directory; it
    /// is not cleaned up automatically.
    static func temporary() throws -> (db: AppDatabase, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VGN-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "VGN.temp"
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: dir.appendingPathComponent("vgn.sqlite").path,
                                    configuration: config)
        return (try AppDatabase(pool), dir)
    }

    // MARK: - Migrator

    /// The one-closure-per-version migrator. v1 holds the ENTIRE PLAN §4 schema
    /// plus `enrichment_jobs` and `app_state`. Later schema changes = new
    /// numbered migrations here (lane A only).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // NEVER set `eraseDatabaseOnSchemaChange`: the owner's real library runs on
        // DEBUG builds. Applied migrations are immutable; schema changes are new
        // numbered migrations.
        Migrations.registerV1(in: &migrator)
        Migrations.registerV2(in: &migrator)
        Migrations.registerV3(in: &migrator)
        Migrations.registerV4(in: &migrator)
        Migrations.registerV5(in: &migrator)
        Migrations.registerV6(in: &migrator)
        Migrations.registerV7(in: &migrator)
        Migrations.registerV8(in: &migrator)
        Migrations.registerV9(in: &migrator)
        Migrations.registerV10(in: &migrator)
        Migrations.registerV11(in: &migrator)
        Migrations.registerV12(in: &migrator)
        return migrator
    }
}
