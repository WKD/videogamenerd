import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v14 (PLAN §5.2/§5.5, D2): `games.cover_provisional` marks an importer-supplied
/// (Delicious) cover as a stopgap the cover job may upgrade. Pure additive `ADD COLUMN` +
/// a one-shot backfill that flags Delicious-origin, not-user-chosen covers that never went
/// through a cover job (the identifiable "the importer supplied it" signal).
@Suite struct MigrationV14Tests {

    @Test func freshDBDefaultsToNotProvisional() async throws {
        let db = try AppDatabase.inMemory()
        let id = try await db.dbWriter.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO games (title, cover_file) VALUES ('G', 'g.png')")
            return db.lastInsertedRowID
        }
        let provisional = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT cover_provisional FROM games WHERE id = ?", arguments: [id])
        }
        #expect(provisional == 0)
    }

    /// The backfill on upgrade from v13.
    @Test func upgradeBackfillsOnlyImporterSuppliedCovers() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV13 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV13)
        Migrations.registerV2(in: &upToV13)
        Migrations.registerV3(in: &upToV13)
        Migrations.registerV4(in: &upToV13)
        Migrations.registerV5(in: &upToV13)
        Migrations.registerV6(in: &upToV13)
        Migrations.registerV7(in: &upToV13)
        Migrations.registerV8(in: &upToV13)
        Migrations.registerV9(in: &upToV13)
        Migrations.registerV10(in: &upToV13)
        Migrations.registerV11(in: &upToV13)
        Migrations.registerV12(in: &upToV13)
        Migrations.registerV13(in: &upToV13)
        try upToV13.migrate(queue)

        // Insert four games covering every case, and one cover job for case B.
        try await queue.write { db in
            // A: Delicious box art, no cover job → SHOULD become provisional.
            try db.execute(sql: """
                INSERT INTO games (id, title, cover_file, origin, user_edited)
                VALUES (1, 'A', 'a.png', 'delicious', '')
                """)
            // B: Delicious, but a cover job ran (its cover came from a provider) → NOT.
            try db.execute(sql: """
                INSERT INTO games (id, title, cover_file, origin, user_edited)
                VALUES (2, 'B', 'b.png', 'delicious', '')
                """)
            try db.execute(sql: """
                INSERT INTO enrichment_jobs (kind, game_id, state, attempts, next_attempt_at, created_at)
                VALUES ('cover', 2, 'done', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                """)
            // C: Delicious, but the owner hand-chose the cover → NOT.
            try db.execute(sql: """
                INSERT INTO games (id, title, cover_file, origin, user_edited)
                VALUES (3, 'C', 'c.png', 'delicious', 'cover')
                """)
            // D: not Delicious → NOT.
            try db.execute(sql: """
                INSERT INTO games (id, title, cover_file, origin, user_edited)
                VALUES (4, 'D', 'd.png', 'manual', '')
                """)
            // E: Delicious but no cover at all → NOT (nothing to keep provisional).
            try db.execute(sql: """
                INSERT INTO games (id, title, cover_file, origin, user_edited)
                VALUES (5, 'E', NULL, 'delicious', '')
                """)
        }

        var full = upToV13
        Migrations.registerV14(in: &full)
        try full.migrate(queue)

        let provisional = try await queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM games WHERE cover_provisional = 1 ORDER BY id")
        }
        #expect(provisional == [1])   // only A
    }
}
