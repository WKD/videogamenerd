import Foundation
import Testing
import GRDB
@testable import VGN

@Suite struct SchemaAndSeedTests {

    @Test func migrationCreatesEveryTable() async throws {
        let db = try AppDatabase.inMemory()
        let expected = [
            "platforms", "games", "game_platforms", "genres", "game_genres",
            "products", "product_games", "tiers", "comparisons", "import_titles",
            "games_fts", "catalog_cache", "enrichment_jobs", "app_state",
        ]
        try await db.dbWriter.read { db in
            for table in expected {
                let exists = try db.tableExists(table)
                #expect(exists, "missing table \(table)")
            }
        }
    }

    @Test func decadeIsGeneratedFromYear() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(GameDraft(title: "Chrono Trigger",
                                                        year: 1995, platformIDs: ["snes"], owned: true))
        let detail = try #require(try await store.gameDetail(id: outcome.gameID))
        #expect(detail.decade == 1990)
    }

    @Test func checkConstraintRejectsTierWithoutPlayed() async throws {
        let db = try await TestDB.makeSeeded()
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT INTO games (title, sort_title, played, tier_id) VALUES ('X','x',0,1)
                    """)
            }
        }
    }

    @Test func defaultTiersSeededSAtoF() async throws {
        let store = try await TestDB.makeStore()
        let tiers = try await store.tiers()
        #expect(tiers.map(\.letter) == ["S", "A", "B", "C", "D", "F"])
        #expect(tiers.first?.label == "Masterpiece")
        #expect(tiers.allSatisfy { $0.colorHex.hasPrefix("#") })
        // Ordered best (0) to worst.
        #expect(tiers.map(\.sort) == [0, 1, 2, 3, 4, 5])
    }

    @Test func platformSeedIsIdempotentAndUpserts() async throws {
        let db = try AppDatabase.inMemory()
        let firstInserted = try await db.seedPlatforms(from: TestDB.platforms)
        #expect(firstInserted == TestDB.platforms.count)

        // Second run inserts nothing new…
        let secondInserted = try await db.seedPlatforms(from: TestDB.platforms)
        #expect(secondInserted == 0)

        // …but refreshes an edited display name without a migration.
        var edited = TestDB.platforms
        let e = edited[0]
        edited[0] = PlatformCatalogEntry(
            id: e.id, name: "PlayStation 5 Pro", short: e.short, manufacturer: e.manufacturer,
            group: e.group, kind: e.kind, generation: e.generation, igdbIDs: e.igdbIDs,
            libretroRepo: e.libretroRepo, sort: e.sort)
        _ = try await db.seedPlatforms(from: edited)
        let store = LibraryStore(db)
        let ps5 = try await store.allPlatforms().first { $0.id == "ps5" }
        #expect(ps5?.name == "PlayStation 5 Pro")
    }

    @Test func bundledPlatformsJSONDecodesAndSeeds() async throws {
        // The real Resources/platforms.json (61 platforms) must decode into
        // PlatformCatalogEntry and upsert. Hosted tests see the app bundle as main.
        let db = try AppDatabase.inMemory()
        let inserted = try await db.seedPlatformsFromBundle(.main)
        #expect(inserted >= 40, "expected the full platform list, got \(inserted)")
        let store = LibraryStore(db)
        let all = try await store.allPlatforms()
        #expect(all.contains { $0.id == "ps5" })
    }

    @Test func platformLookupsByIGDBAndLibretro() async throws {
        let store = try await TestDB.makeStore()
        let ps2 = try await store.platform(igdbID: 8)
        #expect(ps2?.id == "ps2")
        #expect(try await store.libretroRepo(for: "ps2") == "Sony_-_PlayStation_2")
        #expect(try await store.libretroRepo(for: "ps5") == nil)
    }

    @Test func neverDeletesAPlatformThatHasGames() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "God of War", platformIDs: ["ps4"], owned: true))
        // The FK on products.platform_id is ON DELETE RESTRICT.
        await #expect(throws: (any Error).self) {
            try await store.dbWriter.write { db in
                try db.execute(sql: "DELETE FROM platforms WHERE id = 'ps4'")
            }
        }
    }
}
