import Foundation
import GRDB
import Testing
@testable import VGN

/// The ROM Catalogue browser queries (PLAN §15): paged reads, per-system + filter + sort +
/// FTS search — and the library-unaware guarantee that a huge catalogue never changes any
/// library sidebar count.
struct RomCatalogBrowseTests {

    private func seed(_ store: RomCatalogStore) async throws {
        let games: [BatoceraGame] = [
            BatoceraGame(system: "snes", relativePath: "./Zelda (USA).zip", name: "The Legend of Zelda",
                         genre: "Adventure", releaseYear: 1991, rating: 0.9, gameTimeSeconds: 4000),
            BatoceraGame(system: "snes", relativePath: "./Mario (USA).zip", name: "Super Mario World",
                         genre: "Platform", releaseYear: 1990, rating: 0.95, gameTimeSeconds: 0, isFavorite: true),
            BatoceraGame(system: "nes", relativePath: "./Metroid (USA).zip", name: "Metroid",
                         genre: "Platform", releaseYear: 1986, rating: 0.8, gameTimeSeconds: 0),
        ]
        let bySystem = Dictionary(grouping: games, by: \.system)
        for (system, list) in bySystem {
            let entries = list.map { RomCatalogEntry.make(from: $0, platformID: BatoceraSystems.platformSlug(for: system),
                                                          libretroKey: BatoceraFolding.foldKey(for: $0)) }
            _ = try await store.syncSystem(system: system, entries: entries)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func browseFilterSortAndSearch() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store)

        // Per-system counts.
        let counts = try await store.countsPerSystem()
        #expect(counts["snes"] == 2)
        #expect(counts["nes"] == 1)

        // Filter: favourites (Super Mario World only).
        let favs = try await store.browse(system: nil, filter: .favourites, sort: .title,
                                          search: "", limit: 100, offset: 0)
        #expect(favs.map(\.name) == ["Super Mario World"])

        // Filter: never played (Mario + Metroid), scoped to a system.
        let neverSnes = try await store.browse(system: "snes", filter: .neverPlayed, sort: .title,
                                              search: "", limit: 100, offset: 0)
        #expect(neverSnes.map(\.name) == ["Super Mario World"])

        // Sort: most played (Zelda first).
        let played = try await store.browse(system: nil, filter: .all, sort: .mostPlayed,
                                           search: "", limit: 100, offset: 0)
        #expect(played.first?.name == "The Legend of Zelda")

        // FTS search (diacritics-insensitive prefix).
        let hits = try await store.browse(system: nil, filter: .all, sort: .title,
                                         search: "metro", limit: 100, offset: 0)
        #expect(hits.map(\.name) == ["Metroid"])

        // Count matches a filter.
        #expect(try await store.browseCount(system: nil, filter: .favourites, search: "") == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func pagingReturnsDistinctPages() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        var entries: [RomCatalogEntry] = []
        for i in 0..<250 {
            let g = BatoceraGame(system: "snes", relativePath: "./g\(i).zip",
                                 name: String(format: "Game %04d", i))
            entries.append(RomCatalogEntry.make(from: g, platformID: "snes",
                                                libretroKey: BatoceraFolding.foldKey(for: g)))
        }
        _ = try await store.syncSystem(system: "snes", entries: entries)

        let page1 = try await store.browse(system: "snes", filter: .all, sort: .title,
                                          search: "", limit: 100, offset: 0)
        let page2 = try await store.browse(system: "snes", filter: .all, sort: .title,
                                          search: "", limit: 100, offset: 100)
        #expect(page1.count == 100)
        #expect(page2.count == 100)
        #expect(Set(page1.map(\.id)).isDisjoint(with: Set(page2.map(\.id))))
        #expect(try await store.browseCount(system: "snes", filter: .all, search: "") == 250)
    }

    /// PLAN §15: a 10 000-row catalogue must not change ANY library sidebar count.
    @Test(.timeLimit(.minutes(2)))
    func catalogueIsInvisibleToLibraryCounts() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        // A tiny real library.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Real Game', 1)")
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (2, 'Other', 0)")
        }

        func libraryCounts() async throws -> (SidebarCounts, Int, Int) {
            try await db.dbWriter.read { db in
                let counts = try LibraryStore.fetchSidebarCounts(db)
                let lengths = try LibraryQuery.fetchLengthShelfCounts(
                    db, bounds: LengthShelf.bounds(for: .default), style: .default)
                let unlinked = try LibraryQuery.fetchUnlinkedCount(db)
                var c = counts
                c.lengthShelves = lengths.shelves
                c.unmeasured = lengths.unmeasured
                c.unlinked = unlinked
                return (c, lengths.unmeasured, unlinked)
            }
        }

        let before = try await libraryCounts()

        // 10 000 catalogue rows — a full shelf.
        let store = RomCatalogStore(db)
        var entries: [RomCatalogEntry] = []
        entries.reserveCapacity(10_000)
        for i in 0..<10_000 {
            let g = BatoceraGame(system: "snes", relativePath: "./rom\(i).zip", name: "ROM \(i)",
                                 gameTimeSeconds: i % 3 == 0 ? 1000 : 0, isFavorite: i % 5 == 0)
            entries.append(RomCatalogEntry.make(from: g, platformID: "snes",
                                                libretroKey: "rom\(i)"))
        }
        _ = try await store.syncSystem(system: "snes", entries: entries)
        #expect(try await store.totalCount() == 10_000)

        let after = try await libraryCounts()
        #expect(after.0 == before.0)   // every library count is unchanged
        // And the Vault's own count is never part of SidebarCounts.
        #expect(before.0.count(for: .vault(.batocera)) == nil)

        // PLAN §16: PS Plus Vault rows are equally invisible to the library (extend the guard).
        _ = try await store.syncPSNVault(
            entries: (0..<200).map {
                RomCatalogEntry.makePSNVault(externalID: "ent:\($0)", platform: "ps5",
                                             name: "PS \($0)", coverURL: nil, membership: "ps_plus")
            },
            presentExternalIDs: Set((0..<200).map { "ent:\($0)" }))
        #expect(try await store.sourceCounts().psn == 200)
        let afterPSN = try await libraryCounts()
        #expect(afterPSN.0 == before.0)                       // still every library count unchanged
        #expect(before.0.count(for: .vault(.psn)) == nil)     // never part of SidebarCounts
    }
}
