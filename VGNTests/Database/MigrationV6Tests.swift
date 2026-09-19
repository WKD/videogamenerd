import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v6 (PLAN §5.3 + owner request): `games.hltb_id` and `games.origin`,
/// with the origin backfill from the oldest product's source. Fresh DB, upgrade
/// from v5 with mixed data, and the creation-path tagging that keeps a game's
/// origin fixed once set.
@Suite struct MigrationV6Tests {

    static func threw(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch { return true }
    }

    @Test func freshDBHasHLTBIDAndOriginColumns() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, played, hltb_id, origin)
                VALUES (1, 'Bloodborne', 1, 7333, 'photo')
                """)
        }
        let row = try await db.dbWriter.read { db -> (Int64?, String?) in
            let r = try Row.fetchOne(db, sql: "SELECT hltb_id, origin FROM games WHERE id = 1")!
            return (r["hltb_id"], r["origin"])
        }
        #expect(row.0 == 7333)
        #expect(row.1 == "photo")
    }

    @Test func upgradeFromV5BackfillsOriginFromOldestProduct() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV5 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV5)
        Migrations.registerV2(in: &upToV5)
        Migrations.registerV3(in: &upToV5)
        Migrations.registerV4(in: &upToV5)
        Migrations.registerV5(in: &upToV5)
        try upToV5.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
            // g1: single manual product.
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Manual Game', 0)")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source) VALUES (10, 'pc','single','physical','manual')")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (10, 1, 0)")
            // g2: single photo product.
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (2, 'Photo Game', 0)")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source) VALUES (11, 'pc','single','physical','photo')")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (11, 2, 0)")
            // g3: two copies — GOG (older, id 12) then manual (newer, id 13). Oldest wins → gog.
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (3, 'Two Copies', 0)")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source, external_id) VALUES (12, 'pc','single','digital','gog','x1')")
            try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source) VALUES (13, 'pc','single','physical','manual')")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (12, 3, 0)")
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (13, 3, 0)")
            // g4: played-only, no product → 'manual' fallback.
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (4, 'Played Only', 1)")
        }

        var full = upToV5
        Migrations.registerV6(in: &full)
        try full.migrate(queue)

        let origins = try await queue.read { db -> [Int64: String?] in
            var out: [Int64: String?] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT id, origin FROM games ORDER BY id") {
                out[r["id"]] = r["origin"]
            }
            return out
        }
        #expect(origins[1] == "manual")
        #expect(origins[2] == "photo")
        #expect(origins[3] == "gog")     // oldest product (lowest id) wins
        #expect(origins[4] == "manual")  // played-only fallback
    }
}
