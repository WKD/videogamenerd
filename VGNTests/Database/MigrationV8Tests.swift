import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v8 (PLAN §13.3 "PS Plus copies"): `products.subscription TEXT` (NULL = really
/// owned; `'ps_plus'` = a PS Plus claim) plus its partial index. Fresh DB accepts and
/// defaults the column; an upgrade from v7 with data keeps every row + membership and
/// backfills `subscription = NULL`.
@Suite struct MigrationV8Tests {

    private static func seedPlatform(_ db: Database, _ id: String = "pc") throws {
        try db.execute(sql: """
            INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
            VALUES (?, 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
            """, arguments: [id])
    }

    @Test func freshDBHasSubscriptionColumnDefaultingNull() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try Self.seedPlatform(db)
            // A really-owned copy leaves subscription NULL…
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source) VALUES (1, 'pc','single','digital','psn')
                """)
            // …a PS Plus claim stores 'ps_plus'.
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, subscription)
                VALUES (2, 'pc','single','digital','psn','ps_plus')
                """)
        }
        let (owned, plus) = try await db.dbWriter.read { db -> (String?, String?) in
            (try String.fetchOne(db, sql: "SELECT subscription FROM products WHERE id = 1"),
             try String.fetchOne(db, sql: "SELECT subscription FROM products WHERE id = 2"))
        }
        #expect(owned == nil)
        #expect(plus == "ps_plus")
    }

    @Test func partialIndexExistsOverNonNullSubscription() async throws {
        let db = try AppDatabase.inMemory()
        let hasIndex = try await db.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM sqlite_master
                              WHERE type='index' AND name='products_subscription_idx')
                """) ?? false
        }
        #expect(hasIndex)
    }

    @Test func upgradeFromV7KeepsEverythingAndBackfillsNull() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV7 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV7)
        Migrations.registerV2(in: &upToV7)
        Migrations.registerV3(in: &upToV7)
        Migrations.registerV4(in: &upToV7)
        Migrations.registerV5(in: &upToV7)
        Migrations.registerV6(in: &upToV7)
        Migrations.registerV7(in: &upToV7)
        try upToV7.migrate(queue)

        try await queue.write { db in
            try Self.seedPlatform(db)
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'A', 0), (2, 'B', 0)")
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, external_id) VALUES
                    (10, 'pc', 'single', 'digital', 'psn', 'e1'),
                    (11, 'pc', 'compilation', 'physical', 'manual', NULL)
                """)
            try db.execute(sql: """
                INSERT INTO product_games (product_id, game_id, position) VALUES (11, 1, 0), (11, 2, 1)
                """)
        }
        let before = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? -1
        }

        var full = upToV7
        Migrations.registerV8(in: &full)
        try full.migrate(queue)

        let after = try await queue.read { db -> (products: Int, members: Int, nulls: Int, fk: Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = 11") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE subscription IS NULL") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1)
        }
        #expect(after.products == before)   // no rows lost
        #expect(after.members == 2)         // compilation membership preserved
        #expect(after.nulls == before)      // every existing copy backfilled to really-owned
        #expect(after.fk == 0)              // clean foreign-key check

        // The column is writable after the upgrade.
        try await queue.write { db in
            try db.execute(sql: "UPDATE products SET subscription = 'ps_plus' WHERE id = 10")
        }
        let plus = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE subscription = 'ps_plus'")
        }
        #expect(plus == 1)
    }
}
