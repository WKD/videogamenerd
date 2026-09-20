import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v15 (PLAN §4/§7b, owner request 2026-09-20): `games.revisit`, the additive
/// flag behind the "To Revisit" status (a dropped game the owner wants to come back to,
/// stored as `status = 'abandoned' AND revisit = 1`). Pure additive `ADD COLUMN`, no
/// backfill — nothing is guessed for existing games (PLAN §4 inv. 5).
@Suite struct MigrationV15Tests {

    @Test func freshDBDefaultsToZeroAndKeepsStatusCheck() async throws {
        let db = try AppDatabase.inMemory()
        let revisit = try await db.dbWriter.write { db -> Int64? in
            try db.execute(sql: "INSERT INTO games (title, played, status) VALUES ('G', 1, 'abandoned')")
            let id = db.lastInsertedRowID
            return try Int64.fetchOne(db, sql: "SELECT revisit FROM games WHERE id = ?", arguments: [id])
        }
        #expect(revisit == 0)   // default, not guessed

        // The revisit CHECK admits only 0 / 1.
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO games (title, revisit) VALUES ('Bad', 2)")
            }
        }
        // The v1 status CHECK is untouched — 'toRevisit' is NOT a legal status value.
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO games (title, status) VALUES ('Bad', 'toRevisit')")
            }
        }
    }

    /// Upgrading a v14 DB with data leaves every existing game at `revisit = 0` (no backfill).
    @Test func upgradeFromV14AddsColumnWithoutBackfill() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV14 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV14)
        Migrations.registerV2(in: &upToV14)
        Migrations.registerV3(in: &upToV14)
        Migrations.registerV4(in: &upToV14)
        Migrations.registerV5(in: &upToV14)
        Migrations.registerV6(in: &upToV14)
        Migrations.registerV7(in: &upToV14)
        Migrations.registerV8(in: &upToV14)
        Migrations.registerV9(in: &upToV14)
        Migrations.registerV10(in: &upToV14)
        Migrations.registerV11(in: &upToV14)
        Migrations.registerV12(in: &upToV14)
        Migrations.registerV13(in: &upToV14)
        Migrations.registerV14(in: &upToV14)
        try upToV14.migrate(queue)

        try await queue.write { db in
            // An abandoned game that predates the feature must stay plain Abandoned.
            try db.execute(sql: "INSERT INTO games (id, title, played, status) VALUES (1, 'Old Abandoned', 1, 'abandoned')")
            try db.execute(sql: "INSERT INTO games (id, title, played, status) VALUES (2, 'Old Finished', 1, 'finished')")
        }

        var full = upToV14
        Migrations.registerV15(in: &full)
        try full.migrate(queue)

        let flags = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, revisit FROM games ORDER BY id")
                .map { ($0["id"] as Int64, $0["revisit"] as Int64) }
        }
        #expect(flags.first { $0.0 == 1 }?.1 == 0)   // nothing guessed
        #expect(flags.first { $0.0 == 2 }?.1 == 0)
    }
}
