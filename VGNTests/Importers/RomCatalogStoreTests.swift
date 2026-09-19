import Foundation
import Testing
@testable import VGN

/// The catalogue store (PLAN §15): upsert add/update/remove, change-detection state,
/// promotion candidates, FTS search, per-system counts, never-played pool.
struct RomCatalogStoreTests {

    private func entry(_ path: String, name: String, system: String = "snes",
                       slug: String? = "snes", gametime: Int = 0, favorite: Bool = false,
                       genre: String? = nil, family: String? = nil,
                       year: Int? = nil) -> RomCatalogEntry {
        let g = BatoceraGame(system: system, relativePath: "./" + path, name: name,
                             genre: genre, family: family, releaseYear: year,
                             gameTimeSeconds: gametime, isFavorite: favorite)
        return RomCatalogEntry.make(from: g, platformID: slug,
                                    libretroKey: BatoceraFolding.foldKey(for: g))
    }

    @Test func syncSystemInsertsUpdatesAndRemoves() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)

        var c = try await store.syncSystem(system: "snes", entries: [
            entry("Mario.zip", name: "Super Mario World"),
            entry("Metroid.zip", name: "Super Metroid"),
        ])
        #expect(c.added == 2)
        #expect(c.updated == 0)
        #expect(try await store.totalCount() == 2)

        // Re-sync: one updated, one gone (removed, not deleted), one new added.
        c = try await store.syncSystem(system: "snes", entries: [
            entry("Mario.zip", name: "Super Mario World", gametime: 1000),
            entry("Zelda.zip", name: "A Link to the Past"),
        ])
        #expect(c.added == 1)          // Zelda
        #expect(c.updated == 1)        // Mario
        #expect(c.removed == 1)        // Metroid vanished
        #expect(try await store.totalCount() == 2)                       // present rows
        #expect(try await store.totalCount(includeRemoved: true) == 3)   // Metroid still stored
    }

    @Test func changeDetectionState() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        #expect(try await store.syncState(system: "snes") == nil)

        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.setSyncState(system: "snes", mtime: mtime, size: 4242, entryCount: 99)
        let state = try #require(try await store.syncState(system: "snes"))
        #expect(state.gamelistSize == 4242)
        #expect(state.entryCount == 99)
        #expect(state.gamelistMtime.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
    }

    @Test func promotionCandidatesMatchTheRule() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncSystem(system: "snes", entries: [
            entry("a.zip", name: "Played", gametime: 900),          // > 10 min → candidate
            entry("b.zip", name: "Favourite", favorite: true),       // favourite → candidate
            entry("c.zip", name: "Barely", gametime: 200),           // < 10 min, not fav → no
            entry("d.zip", name: "Exactly600", gametime: 600),       // == 600 not > → no
        ])
        let names = Set(try await store.promotionCandidates().map(\.name))
        #expect(names == ["Played", "Favourite"])
    }

    @Test func searchIsDiacriticsInsensitivePrefix() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncSystem(system: "snes", entries: [
            entry("p.zip", name: "Pokémon Red"),
            entry("z.zip", name: "The Legend of Zelda"),
        ])
        #expect(try await store.search("pokemon").map(\.name) == ["Pokémon Red"])
        #expect(try await store.search("zel").first?.name == "The Legend of Zelda")   // prefix
        #expect(try await store.search("nothinghere").isEmpty)
    }

    @Test func countsAndNeverPlayedPool() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncSystem(system: "snes", entries: [
            entry("a.zip", name: "Never A"),
            entry("b.zip", name: "Played B", gametime: 1000),
        ])
        _ = try await store.syncSystem(system: "nes", entries: [
            entry("c.zip", name: "Never C", system: "nes", slug: "nes"),
        ])
        let counts = try await store.countsPerSystem()
        #expect(counts["snes"] == 2)
        #expect(counts["nes"] == 1)

        let never = try await store.neverPlayedPool().map(\.name)
        #expect(Set(never) == ["Never A", "Never C"])
    }

    @Test func setPromotedLinksCatalogueRow() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncSystem(system: "snes", entries: [entry("a.zip", name: "A", gametime: 999)])
        let candidate = try #require(try await store.promotionCandidates().first)
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (42, 'A', 1)")
        }
        try await store.setPromoted(catalogID: candidate.id, gameID: 42)
        // Now no longer a candidate (already promoted).
        #expect(try await store.promotionCandidates().isEmpty)
        let reloaded = try #require(try await store.entry(id: candidate.id))
        #expect(reloaded.promotedGameID == 42)
    }
}
