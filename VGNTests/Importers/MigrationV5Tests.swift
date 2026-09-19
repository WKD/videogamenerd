import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v5 (PLAN §14.2/§14.3): `import_cache`, `import_cache_rejects`,
/// `products.external_id` + the partial unique index, and the widened `products.source`
/// CHECK. Fresh DB and upgrade-from-v4-with-data.
@Suite struct MigrationV5Tests {

    static func threw(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch { return true }
    }

    @Test func freshDBHasImportCacheAndProductExternalID() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('gog_pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
            // import_cache accepts a row.
            try db.execute(sql: """
                INSERT INTO import_cache (source, key, endpoint, fetched_at, expires_at, status, body, item_count)
                VALUES ('gog', 'k', 'e', '2024-01-01', '2024-02-01', 200, x'7b7d', 3)
                """)
            // import_cache_rejects accepts a row.
            try db.execute(sql: """
                INSERT INTO import_cache_rejects (source, endpoint, received_at, reason)
                VALUES ('gog', 'e', '2024-01-01', 'notJSON')
                """)
            // products now takes source='gog' + external_id.
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, external_id)
                VALUES (1, 'gog_pc', 'single', 'digital', 'gog', '100001')
                """)
        }
        let counts = try await db.dbWriter.read { db -> (Int, Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_cache") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_cache_rejects") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='gog'") ?? -1)
        }
        #expect(counts == (1, 1, 1))
    }

    @Test func partialUniqueIndexRejectsDuplicateSourceExternalID() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, external_id)
                VALUES ('pc', 'single', 'digital', 'gog', '555')
                """)
        }
        // A second product with the same (source, external_id) is rejected.
        let duped = await Self.threw {
            try await db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO products (platform_id, kind, format, source, external_id)
                    VALUES ('pc', 'single', 'digital', 'gog', '555')
                    """)
            }
        }
        #expect(duped)
        // But two products with NULL external_id are fine (the index is partial).
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','physical','manual')")
            try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','physical','manual')")
        }
        let manualCount = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='manual'")
        }
        #expect(manualCount == 2)
    }

    @Test func upgradeFromV4WithDataKeepsEverything() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV4 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV4)
        Migrations.registerV2(in: &upToV4)
        Migrations.registerV3(in: &upToV4)
        Migrations.registerV4(in: &upToV4)
        try upToV4.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Existing Game', 1)")
            // A pre-existing product + compilation membership v5's rebuild must keep.
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source)
                VALUES (7, 'pc', 'single', 'digital', 'manual')
                """)
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (7, 1, 0)")
        }

        var full = upToV4
        Migrations.registerV5(in: &full)
        try full.migrate(queue)

        let kept = try await queue.read { db -> (products: Int, members: Int, externalID: String?) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE id = 7") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = 7") ?? -1,
             try String.fetchOne(db, sql: "SELECT external_id FROM products WHERE id = 7"))
        }
        #expect(kept.products == 1)
        #expect(kept.members == 1)
        #expect(kept.externalID == nil)   // external_id exists and is NULL for the migrated row
        // v5 widened source to allow 'gog'; the old CHECK rejected it.
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, external_id)
                VALUES ('pc', 'single', 'digital', 'gog', '900')
                """)
        }
        let gog = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='gog'")
        }
        #expect(gog == 1)

        // The widened CHECK still rejects a nonsense source.
        let bad = await Self.threw {
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','digital','steam')
                    """)
            }
        }
        #expect(bad)
    }
}
