import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v10 (PLAN §15): the `rom_catalog` / `rom_catalog_sync` tables + FTS. Fresh DB
/// has them empty; an upgrade from v9 keeps every game and adds an empty catalogue;
/// `(source, system, relative_path)` is unique; `promoted_game_id` goes NULL when the game
/// is deleted (never blocks the delete, never cascades the catalogue row away).
@Suite struct BatoceraMigrationV10Tests {

    @Test func freshDBHasEmptyCatalogueTables() async throws {
        let db = try AppDatabase.inMemory()
        let (rows, syncRows, hasFTS) = try await db.dbWriter.read { db -> (Int, Int, Bool) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog_sync") ?? -1,
             try db.tableExists("rom_catalog_fts"))
        }
        #expect(rows == 0)
        #expect(syncRows == 0)
        #expect(hasFTS)
    }

    @Test func uniqueOnSourceSystemPath() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog (source, system, relative_path, name)
                VALUES ('batocera', 'snes', './A.zip', 'A')
                """)
        }
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO rom_catalog (source, system, relative_path, name)
                    VALUES ('batocera', 'snes', './A.zip', 'A again')
                    """)
            }
        }
    }

    @Test func promotedGameIDGoesNullWhenGameDeleted() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (7, 'G', 1)")
            try db.execute(sql: """
                INSERT INTO rom_catalog (id, source, system, relative_path, name, promoted_game_id)
                VALUES (1, 'batocera', 'snes', './A.zip', 'A', 7)
                """)
        }
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM games WHERE id = 7")
        }
        let (rowStillThere, promoted) = try await db.dbWriter.read { db -> (Int, Int64?) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog WHERE id = 1") ?? -1,
             try Int64.fetchOne(db, sql: "SELECT promoted_game_id FROM rom_catalog WHERE id = 1"))
        }
        #expect(rowStillThere == 1)   // catalogue row survives
        #expect(promoted == nil)      // link cleared
    }

    @Test func upgradeFromV9KeepsGamesAndAddsEmptyCatalogue() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV9 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV9)
        Migrations.registerV2(in: &upToV9)
        Migrations.registerV3(in: &upToV9)
        Migrations.registerV4(in: &upToV9)
        Migrations.registerV5(in: &upToV9)
        Migrations.registerV6(in: &upToV9)
        Migrations.registerV7(in: &upToV9)
        Migrations.registerV8(in: &upToV9)
        Migrations.registerV9(in: &upToV9)
        try upToV9.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'A', 1), (2, 'B', 0)")
        }
        let before = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1 }

        var full = upToV9
        Migrations.registerV10(in: &full)
        try full.migrate(queue)

        let (games, catalogue) = try await queue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1)
        }
        #expect(games == before)
        #expect(catalogue == 0)
    }
}
