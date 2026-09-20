import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v11 (PLAN §16 — The Vault): `rom_catalog` gains the nullable PS Plus columns
/// (external id, cover url, membership, cross-gen note, IGDB id + traits + time-to-beat +
/// rating, match state / matched-at). A fresh DB has them; an upgrade from v10 with Batocera
/// rows present keeps every row and every value, adds the columns as NULL, and the FTS still
/// works. A PS Plus row (source = psn, system = platform slug, relative_path = external id)
/// coexists with a Batocera row of the same relative_path without violating uniqueness.
@Suite struct VaultMigrationV11Tests {

    @Test func freshDBHasVaultColumns() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog
                    (source, system, relative_path, name, external_id, cover_url, membership,
                     cross_gen_note, igdb_id, length_main_s, length_complete_s, traits_json,
                     igdb_rating, match_state, matched_at)
                VALUES ('psn', 'ps5', 'ent:42', 'Bloodborne', 'ent:42',
                        'https://x/cover.png', 'ps_plus', 'PS4 & PS5 versions', 7346,
                        36000, 108000, '[]', 88.0, 'matched', CURRENT_TIMESTAMP)
                """)
        }
        let (membership, igdbID, matchState, lengthMain) = try await db.dbWriter.read {
            db -> (String?, Int64?, String?, Int64?) in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM rom_catalog WHERE external_id = 'ent:42'")
            return (row?["membership"], row?["igdb_id"], row?["match_state"], row?["length_main_s"])
        }
        #expect(membership == "ps_plus")
        #expect(igdbID == Int64(7346))
        #expect(matchState == "matched")
        #expect(lengthMain == Int64(36000))
    }

    @Test func psnAndBatoceraRowsCoexist() async throws {
        let db = try AppDatabase.inMemory()
        // Same relative_path on both sources is allowed (unique is per-source).
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog (source, system, relative_path, name)
                VALUES ('batocera', 'snes', 'ent:42', 'A'),
                       ('psn', 'ps5', 'ent:42', 'B')
                """)
        }
        let n = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1
        }
        #expect(n == 2)
    }

    @Test func upgradeFromV10KeepsBatoceraRows() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV10 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV10)
        Migrations.registerV2(in: &upToV10)
        Migrations.registerV3(in: &upToV10)
        Migrations.registerV4(in: &upToV10)
        Migrations.registerV5(in: &upToV10)
        Migrations.registerV6(in: &upToV10)
        Migrations.registerV7(in: &upToV10)
        Migrations.registerV8(in: &upToV10)
        Migrations.registerV9(in: &upToV10)
        Migrations.registerV10(in: &upToV10)
        try upToV10.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog (id, source, system, relative_path, name,
                                         normalised_title, game_time_s, favorite)
                VALUES (1, 'batocera', 'snes', './Zelda.zip', 'Zelda', 'zelda', 900, 1),
                       (2, 'batocera', 'nes',  './Mario.zip', 'Mario', 'mario', 0, 0)
                """)
        }
        let before = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1
        }

        var full = upToV10
        Migrations.registerV11(in: &full)
        try full.migrate(queue)

        let (count, gt, nilMembership, ftsHit) = try await queue.read { db -> (Int, Int64?, Bool, Int) in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1
            let gt = try Int64.fetchOne(db, sql: "SELECT game_time_s FROM rom_catalog WHERE id = 1")
            let membership = try DatabaseValue.fetchOne(db, sql: "SELECT membership FROM rom_catalog WHERE id = 1")
            // FTS still matches after the ALTERs (external content unchanged).
            let ftsHit = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM rom_catalog c JOIN rom_catalog_fts f ON f.rowid = c.id
                WHERE rom_catalog_fts MATCH 'zelda*'
                """) ?? -1
            return (count, gt, membership?.isNull ?? false, ftsHit)
        }
        #expect(count == before)             // no rows lost
        #expect(gt == Int64(900))            // values preserved
        #expect(nilMembership)               // new column defaults NULL
        #expect(ftsHit == 1)                 // FTS still works
    }
}
