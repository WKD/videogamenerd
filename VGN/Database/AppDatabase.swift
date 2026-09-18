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
        let db = try AppDatabase(pool)
        return db
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
        #if DEBUG
        // In development, wiping-and-recreating on a schema edit beats writing a
        // throwaway migration for a store that holds nothing precious yet.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        Migrations.registerV1(in: &migrator)
        return migrator
    }
}
