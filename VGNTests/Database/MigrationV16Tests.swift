import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v16 (PLAN §4/§7b, owner request 2026-09-25): `games.holds_up`, the optional
/// "Holds up today?" mark. Pure additive `ADD COLUMN` with a vocabulary CHECK, NULL =
/// unrated, **no backfill** — nothing inferred from year / platform / tier (PLAN §4 inv. 5).
@Suite struct MigrationV16Tests {

    @Test func freshDBDefaultsToNullAndChecksTheVocabulary() async throws {
        let db = try AppDatabase.inMemory()
        let value = try await db.dbWriter.write { db -> String? in
            try db.execute(sql: "INSERT INTO games (title, played) VALUES ('G', 1)")
            let id = db.lastInsertedRowID
            return try String.fetchOne(db, sql: "SELECT holds_up FROM games WHERE id = ?", arguments: [id])
        }
        #expect(value == nil)   // unrated by default, never guessed

        // Every legal value is accepted…
        for raw in ["holds_up", "of_its_time", "too_archaic"] {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO games (title, played, holds_up) VALUES ('OK', 1, ?)", arguments: [raw])
            }
        }
        // …and anything else is refused by the CHECK.
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO games (title, played, holds_up) VALUES ('Bad', 1, 'great')")
            }
        }
        // The model's raw values ARE the CHECK vocabulary.
        #expect(Set(HoldsUp.allCases.map(\.dbValue)) == ["holds_up", "of_its_time", "too_archaic"])
    }

    /// Upgrading a v15 DB with data leaves every existing game unrated (no backfill), and
    /// every other column untouched.
    @Test func upgradeFromV15AddsColumnWithoutBackfill() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV15 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV15)
        Migrations.registerV2(in: &upToV15)
        Migrations.registerV3(in: &upToV15)
        Migrations.registerV4(in: &upToV15)
        Migrations.registerV5(in: &upToV15)
        Migrations.registerV6(in: &upToV15)
        Migrations.registerV7(in: &upToV15)
        Migrations.registerV8(in: &upToV15)
        Migrations.registerV9(in: &upToV15)
        Migrations.registerV10(in: &upToV15)
        Migrations.registerV11(in: &upToV15)
        Migrations.registerV12(in: &upToV15)
        Migrations.registerV13(in: &upToV15)
        Migrations.registerV14(in: &upToV15)
        Migrations.registerV15(in: &upToV15)
        try upToV15.migrate(queue)

        try await queue.write { db in
            // An old S-tier 1986 game — the nostalgic case: nothing may be inferred for it.
            try db.execute(sql: """
                INSERT INTO games (id, title, year, played, status, tier_id)
                VALUES (1, 'Super Mario Bros.', 1986, 1, 'finished', 1)
                """)
            try db.execute(sql: "INSERT INTO games (id, title, played, status, revisit) VALUES (2, 'Dropped', 1, 'abandoned', 1)")
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (3, 'Unplayed', 0)")
        }

        var full = upToV15
        Migrations.registerV16(in: &full)
        try full.migrate(queue)

        let rows = try queue.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT id, holds_up, status, revisit, tier_id, year FROM games ORDER BY id")
        }
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { ($0["holds_up"] as String?) == nil })   // nothing guessed
        #expect((rows[0]["tier_id"] as Int64?) == 1)
        #expect((rows[0]["year"] as Int?) == 1986)
        #expect((rows[1]["status"] as String?) == "abandoned")
        #expect((rows[1]["revisit"] as Int64?) == 1)
    }
}
