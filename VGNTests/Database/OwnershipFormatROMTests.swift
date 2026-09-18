import Foundation
import Testing
import GRDB
@testable import VGN

/// Ownership format `rom` (PLAN §4, wave-2 addition): the v3 migration widens the
/// `products.format` CHECK, and ROM surfaces through the store, the filter, and
/// the grid summary.
@Suite struct OwnershipFormatROMTests {

    // MARK: - Migration from a populated v1 database

    @Test func v3MigrationKeepsExistingProductsAndForeignKeys() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        // Apply v1 only, then seed a platform + game + product + link.
        var v1 = DatabaseMigrator()
        Migrations.registerV1(in: &v1)
        try v1.migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('ps2', 'PlayStation 2', 'PS2', 'Sony', 'Sony', 'console', 1)
                """)
            try db.execute(sql: "INSERT INTO games (title, played) VALUES ('X', 1)")
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source)
                VALUES ('ps2', 'single', 'physical', 'manual')
                """)
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (1, 1, 0)")
        }

        // Migrate up through v2 + v3.
        var full = DatabaseMigrator()
        Migrations.registerV1(in: &full)
        Migrations.registerV2(in: &full)
        Migrations.registerV3(in: &full)
        try full.migrate(queue)

        let after = try await queue.read { db in
            (products: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products") ?? -1,
             format: try String.fetchOne(db, sql: "SELECT format FROM products WHERE id = 1") ?? "",
             links: try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM product_games WHERE product_id = 1 AND game_id = 1") ?? -1)
        }
        #expect(after.products == 1)
        #expect(after.format == "physical")
        #expect(after.links == 1)

        // ON DELETE RESTRICT on platform_id survived the rebuild.
        await #expect(throws: (any Error).self) {
            try await queue.write { db in try db.execute(sql: "DELETE FROM platforms WHERE id = 'ps2'") }
        }
        // The widened CHECK now allows 'rom'…
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source)
                VALUES ('ps2', 'single', 'rom', 'manual')
                """)
        }
        // …but still rejects garbage.
        await #expect(throws: (any Error).self) {
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO products (platform_id, kind, format, source)
                    VALUES ('ps2', 'single', 'floppy', 'manual')
                    """)
            }
        }
        // Cascade still works: deleting the product removes its member link.
        try await queue.write { db in try db.execute(sql: "DELETE FROM products WHERE id = 1") }
        let remainingLinks = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = 1") ?? -1
        }
        #expect(remainingLinks == 0)
    }

    // MARK: - ROM round-trips through the store

    @Test func romProductRoundTrips() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Chrono Trigger", platformIDs: ["snes"], owned: true, format: .rom)).gameID
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.copies.first?.format == .rom)
        #expect(ProductFormat.rom.label == "ROM")
    }

    // MARK: - Format facet + hasROM

    @Test func formatFilterAloneAndCombinedWithPlatform() async throws {
        let store = try await TestDB.makeStore()
        let rom = try await store.addGame(GameDraft(
            title: "SMW", platformIDs: ["snes"], owned: true, format: .rom)).gameID
        let physical = try await store.addGame(GameDraft(
            title: "Bloodborne", platformIDs: ["ps4"], owned: true, format: .physical)).gameID
        let romPS2 = try await store.addGame(GameDraft(
            title: "ICO", platformIDs: ["ps2"], owned: true, format: .rom)).gameID

        func ids(_ filter: LibraryFilter) async throws -> Set<Int64> {
            Set(try await store.gamesOnce(filter: filter).map(\.id))
        }
        // ROM alone.
        #expect(try await ids(LibraryFilter(formats: [.rom])) == [rom, romPS2])
        #expect(try await ids(LibraryFilter(formats: [.physical])) == [physical])
        // ROM AND platform snes.
        #expect(try await ids(LibraryFilter(formats: [.rom], platform: "snes")) == [rom])
    }

    @Test func hasROMFlagInGridSummary() async throws {
        let store = try await TestDB.makeStore()
        let rom = try await store.addGame(GameDraft(
            title: "SMW", platformIDs: ["snes"], owned: true, format: .rom)).gameID
        let physical = try await store.addGame(GameDraft(
            title: "Bloodborne", platformIDs: ["ps4"], owned: true, format: .physical)).gameID

        let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        #expect(rows.first { $0.id == rom }?.hasROM == true)
        #expect(rows.first { $0.id == physical }?.hasROM == false)
    }
}
