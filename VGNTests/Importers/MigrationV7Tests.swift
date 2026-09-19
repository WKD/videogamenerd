import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v7 (PLAN §5.5): the `products.source` CHECK is dropped (validated in Swift
/// via ``ProductSource`` now) so future importers need no rebuild. Fresh DB, the partial
/// unique index survives, and an upgrade from v6 keeps every row + compilation membership
/// with a clean foreign-key check.
@Suite struct MigrationV7Tests {

    static func threw(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return false } catch { return true }
    }

    private static func seedPlatform(_ db: Database, _ id: String = "pc") throws {
        try db.execute(sql: """
            INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
            VALUES (?, 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
            """, arguments: [id])
    }

    @Test func freshDBHasNoSourceCheck() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try Self.seedPlatform(db)
            // The new 'delicious' source is accepted…
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, external_id)
                VALUES ('pc', 'single', 'physical', 'delicious', 'uuid-1')
                """)
            // …and so is any other string (validation moved to Swift/ProductSource).
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','physical','steam')
                """)
        }
        let count = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products")
        }
        #expect(count == 2)
    }

    @Test func partialUniqueSourceExternalStillEnforced() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try Self.seedPlatform(db)
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, external_id)
                VALUES ('pc', 'single', 'physical', 'delicious', 'dup')
                """)
        }
        let duped = await Self.threw {
            try await db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO products (platform_id, kind, format, source, external_id)
                    VALUES ('pc', 'single', 'physical', 'delicious', 'dup')
                    """)
            }
        }
        #expect(duped)
    }

    @Test func upgradeFromV6KeepsEverythingAndAllowsDelicious() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV6 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV6)
        Migrations.registerV2(in: &upToV6)
        Migrations.registerV3(in: &upToV6)
        Migrations.registerV4(in: &upToV6)
        Migrations.registerV5(in: &upToV6)
        Migrations.registerV6(in: &upToV6)
        try upToV6.migrate(queue)

        try await queue.write { db in
            try Self.seedPlatform(db)
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'A', 0), (2, 'B', 0)")
            // One product of every currently-valid source + a compilation with members.
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, external_id) VALUES
                    (10, 'pc', 'single', 'physical', 'manual', NULL),
                    (11, 'pc', 'single', 'physical', 'photo',  NULL),
                    (12, 'pc', 'single', 'digital',  'gog',    'g1'),
                    (13, 'pc', 'compilation', 'physical', 'manual', NULL)
                """)
            try db.execute(sql: """
                INSERT INTO product_games (product_id, game_id, position) VALUES (13, 1, 0), (13, 2, 1)
                """)
        }
        let before = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? -1
        }

        var full = upToV6
        Migrations.registerV7(in: &full)
        try full.migrate(queue)

        let after = try await queue.read { db -> (products: Int, members: Int, fkViolations: Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = 13") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pragma_foreign_key_check") ?? -1)
        }
        #expect(after.products == before)   // no rows lost in the rebuild
        #expect(after.members == 2)         // compilation membership preserved
        #expect(after.fkViolations == 0)    // foreign_key_check is empty

        // 'delicious' now inserts (the v6 CHECK rejected it).
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, external_id)
                VALUES ('pc', 'single', 'physical', 'delicious', 'd1')
                """)
        }
        let delicious = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='delicious'")
        }
        #expect(delicious == 1)
    }
}
