import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v9 (PLAN §13.3, PSN import): `games.first_played_at` / `games.last_played_at`
/// (nullable, importer-filled). Fresh DB accepts + defaults the columns to NULL; an upgrade
/// from v8 with data keeps every row and adds the columns as NULL. Also covers the monotonic,
/// NULL-safe write helper ``LibraryStore/setPSNPlayedDates(gameID:first:last:db:)``.
@Suite struct MigrationV9Tests {

    private static func seedPlayedGame(_ db: Database, id: Int64 = 1) throws {
        try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (?, 'A', 1)", arguments: [id])
    }

    @Test func freshDBHasPlayedDateColumnsDefaultingNull() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in try Self.seedPlayedGame(db) }
        let (first, last) = try await db.dbWriter.read { db -> (Date?, Date?) in
            (try Date.fetchOne(db, sql: "SELECT first_played_at FROM games WHERE id = 1"),
             try Date.fetchOne(db, sql: "SELECT last_played_at FROM games WHERE id = 1"))
        }
        #expect(first == nil)
        #expect(last == nil)
    }

    @Test func upgradeFromV8KeepsEverythingAndAddsColumns() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV8 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV8)
        Migrations.registerV2(in: &upToV8)
        Migrations.registerV3(in: &upToV8)
        Migrations.registerV4(in: &upToV8)
        Migrations.registerV5(in: &upToV8)
        Migrations.registerV6(in: &upToV8)
        Migrations.registerV7(in: &upToV8)
        Migrations.registerV8(in: &upToV8)
        try upToV8.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'A', 1), (2, 'B', 0)")
        }
        let before = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1 }

        var full = upToV8
        Migrations.registerV9(in: &full)
        try full.migrate(queue)

        let (count, nulls) = try await queue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE last_played_at IS NULL AND first_played_at IS NULL") ?? -1)
        }
        #expect(count == before)   // no rows lost
        #expect(nulls == before)   // every existing game backfilled to NULL (unknown)

        // The columns are writable after the upgrade.
        try await queue.write { db in
            try LibraryStore.setPSNPlayedDates(gameID: 1, first: Date(timeIntervalSince1970: 1_000),
                                               last: Date(timeIntervalSince1970: 2_000), db: db)
        }
        let known = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE last_played_at IS NOT NULL")
        }
        #expect(known == 1)
    }

    @Test func setPSNPlayedDatesIsMonotonicAndNullSafe() async throws {
        let db = try AppDatabase.inMemory()
        let early = Date(timeIntervalSince1970: 1_000_000)
        let mid   = Date(timeIntervalSince1970: 2_000_000)
        let late  = Date(timeIntervalSince1970: 3_000_000)

        try await db.dbWriter.write { db in
            try Self.seedPlayedGame(db)
            // First write establishes both.
            try LibraryStore.setPSNPlayedDates(gameID: 1, first: mid, last: mid, db: db)
        }
        func read() async throws -> (Date?, Date?) {
            try await db.dbWriter.read { db in
                (try Date.fetchOne(db, sql: "SELECT first_played_at FROM games WHERE id = 1"),
                 try Date.fetchOne(db, sql: "SELECT last_played_at FROM games WHERE id = 1"))
            }
        }
        var (first, last) = try await read()
        #expect(first.map { Int($0.timeIntervalSince1970) } == 2_000_000)
        #expect(last.map { Int($0.timeIntervalSince1970) } == 2_000_000)

        // An earlier `first` moves first back; an earlier `last` must NOT move last back.
        try await db.dbWriter.write { db in
            try LibraryStore.setPSNPlayedDates(gameID: 1, first: early, last: early, db: db)
        }
        (first, last) = try await read()
        #expect(first.map { Int($0.timeIntervalSince1970) } == 1_000_000)   // moved earlier
        #expect(last.map { Int($0.timeIntervalSince1970) } == 2_000_000)    // never moved back

        // A later `last` moves last forward; a later `first` must NOT move first forward.
        try await db.dbWriter.write { db in
            try LibraryStore.setPSNPlayedDates(gameID: 1, first: late, last: late, db: db)
        }
        (first, last) = try await read()
        #expect(first.map { Int($0.timeIntervalSince1970) } == 1_000_000)   // never moved later
        #expect(last.map { Int($0.timeIntervalSince1970) } == 3_000_000)    // moved later

        // A nil never overwrites a known value; both nil is a no-op.
        try await db.dbWriter.write { db in
            try LibraryStore.setPSNPlayedDates(gameID: 1, first: nil, last: nil, db: db)
        }
        (first, last) = try await read()
        #expect(first.map { Int($0.timeIntervalSince1970) } == 1_000_000)
        #expect(last.map { Int($0.timeIntervalSince1970) } == 3_000_000)
    }
}
