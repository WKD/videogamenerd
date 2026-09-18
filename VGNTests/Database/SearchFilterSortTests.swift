import Foundation
import Testing
import GRDB
@testable import VGN

@Suite struct SearchFilterSortTests {

    /// A small, known library shared by the filter/sort/sidebar tests.
    /// Returns title → gameID.
    private func buildLibrary(_ store: LibraryStore) async throws -> [String: Int64] {
        var ids: [String: Int64] = [:]
        // G1 Bloodborne — ps4, owned+played, tier S(1), 2015, Action, finished.
        ids["Bloodborne"] = try await store.addGame(GameDraft(
            title: "Bloodborne", igdbID: 1, year: 2015, platformIDs: ["ps4"],
            owned: true, tierID: 1, status: .finished)).gameID
        // G2 Gran Turismo — ps4, owned only (backlog), 2017.
        ids["Gran Turismo"] = try await store.addGame(GameDraft(
            title: "Gran Turismo", igdbID: 2, year: 2017, platformIDs: ["ps4"], owned: true)).gameID
        // G3 Broken Sword — pc, played only, alt "Baphomet", 1996, Adventure.
        ids["Broken Sword"] = try await store.addGame(GameDraft(
            title: "Broken Sword", igdbID: 3, year: 1996,
            altTitles: ["Les Chevaliers de Baphomet"], platformIDs: ["pc"], played: true)).gameID
        // G4 Journey — ps4, owned+played, unranked, 2012, Adventure, completed.
        ids["Journey"] = try await store.addGame(GameDraft(
            title: "Journey", igdbID: 4, year: 2012, platformIDs: ["ps4"],
            owned: true, played: true, status: .completed)).gameID
        // G5 Chrono Trigger — snes, owned+played, tier A(2), 1995, RPG.
        ids["Chrono Trigger"] = try await store.addGame(GameDraft(
            title: "Chrono Trigger", igdbID: 5, year: 1995, platformIDs: ["snes"],
            owned: true, tierID: 2)).gameID

        try await store.updateMetadata(gameID: ids["Bloodborne"]!, MetadataPatch(genres: ["Action"]))
        try await store.updateMetadata(gameID: ids["Broken Sword"]!, MetadataPatch(genres: ["Adventure"]))
        try await store.updateMetadata(gameID: ids["Journey"]!, MetadataPatch(genres: ["Adventure"]))
        try await store.updateMetadata(gameID: ids["Chrono Trigger"]!, MetadataPatch(genres: ["RPG"]))
        return ids
    }

    private func titles(_ store: LibraryStore, _ filter: LibraryFilter) async throws -> Set<String> {
        Set(try await store.gamesOnce(filter: filter).map(\.title))
    }

    // MARK: - Sidebar counts

    @Test func sidebarCountsOnConstructedLibrary() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        let c = try await store.sidebarCountsOnce()
        #expect(c.all == 5)
        #expect(c.owned == 4)         // all but Broken Sword
        #expect(c.played == 4)        // all but Gran Turismo
        #expect(c.backlog == 1)       // Gran Turismo
        #expect(c.unranked == 2)      // Broken Sword, Journey
        #expect(c.duelQueue == 2)     // Bloodborne, Chrono Trigger (tiered, no rank_key)
        #expect(c.perPlatform["ps4"] == 3)
        #expect(c.perPlatform["pc"] == 1)
        #expect(c.perPlatform["snes"] == 1)
    }

    // MARK: - Scopes

    @Test func scopeFilters() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(scope: .all)).count == 5)
        #expect(try await titles(store, LibraryFilter(scope: .owned)) ==
                ["Bloodborne", "Gran Turismo", "Journey", "Chrono Trigger"])
        #expect(try await titles(store, LibraryFilter(scope: .backlog)) == ["Gran Turismo"])
        #expect(try await titles(store, LibraryFilter(scope: .unranked)) == ["Broken Sword", "Journey"])
        #expect(try await titles(store, LibraryFilter(scope: .platform("ps4"))) ==
                ["Bloodborne", "Gran Turismo", "Journey"])
    }

    // MARK: - Facets, OR within a kind

    @Test func tierFilterORsWithinKind() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(tierIDs: [1])) == ["Bloodborne"])
        #expect(try await titles(store, LibraryFilter(tierIDs: [1, 2])) == ["Bloodborne", "Chrono Trigger"])
    }

    @Test func decadeFilter() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(decades: [1990])) == ["Broken Sword", "Chrono Trigger"])
        #expect(try await titles(store, LibraryFilter(decades: [2010])) ==
                ["Bloodborne", "Gran Turismo", "Journey"])
    }

    @Test func statusFilter() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(statuses: [.finished])) == ["Bloodborne"])
        #expect(try await titles(store, LibraryFilter(statuses: [.completed])) == ["Journey"])
    }

    @Test func genreFilter() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(genres: ["Adventure"])) == ["Broken Sword", "Journey"])
        #expect(try await titles(store, LibraryFilter(genres: ["RPG"])) == ["Chrono Trigger"])
    }

    // MARK: - Facets, AND across kinds

    @Test func facetsANDAcrossKinds() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        // platform ps4 AND tier S.
        #expect(try await titles(store,
            LibraryFilter(tierIDs: [1], platform: "ps4")) == ["Bloodborne"])
        // scope owned AND genre RPG.
        #expect(try await titles(store,
            LibraryFilter(genres: ["RPG"], scope: .owned)) == ["Chrono Trigger"])
        // platform ps4 AND decade 2010s.
        #expect(try await titles(store,
            LibraryFilter(decades: [2010], platform: "ps4")) ==
            ["Bloodborne", "Gran Turismo", "Journey"])
    }

    // MARK: - FTS

    @Test func ftsFindsByTitlePrefixAndAltTitle() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        #expect(try await titles(store, LibraryFilter(searchText: "blood")) == ["Bloodborne"])
        #expect(try await titles(store, LibraryFilter(searchText: "Baphomet")) == ["Broken Sword"])
        #expect(try await titles(store, LibraryFilter(searchText: "chrono trig")) == ["Chrono Trigger"])
    }

    @Test func ftsStaysInSyncOnUpdateAndDelete() async throws {
        let store = try await TestDB.makeStore()
        let ids = try await buildLibrary(store)
        // Rewriting alt titles removes the old term from the index.
        try await store.updateMetadata(gameID: ids["Broken Sword"]!,
                                       MetadataPatch(altTitles: ["Something Else"]))
        #expect(try await titles(store, LibraryFilter(searchText: "Baphomet")).isEmpty)
        #expect(try await titles(store, LibraryFilter(searchText: "Something")) == ["Broken Sword"])
        // Deleting a game drops it from the index.
        try await store.deleteGame(ids["Bloodborne"]!)
        #expect(try await titles(store, LibraryFilter(searchText: "blood")).isEmpty)
    }

    // MARK: - Sorts

    @Test func sortByTitleStripsLeadingArticles() async throws {
        let store = try await TestDB.makeStore()
        // "The Last of Us" must sort under L, not T.
        _ = try await store.addGame(GameDraft(title: "The Last of Us", platformIDs: ["ps4"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Baldur's Gate", platformIDs: ["pc"], owned: true))
        _ = try await store.addGame(GameDraft(title: "Mario", platformIDs: ["snes"], owned: true))
        let ordered = try await store.gamesOnce(filter: LibraryFilter(sort: .title, ascending: true))
        #expect(ordered.map(\.title) == ["Baldur's Gate", "The Last of Us", "Mario"])
    }

    @Test func sortByYearBothDirections() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        let asc = try await store.gamesOnce(filter: LibraryFilter(sort: .year, ascending: true))
        #expect(asc.map(\.title) == ["Chrono Trigger", "Broken Sword", "Journey", "Bloodborne", "Gran Turismo"])
        let desc = try await store.gamesOnce(filter: LibraryFilter(sort: .year, ascending: false))
        #expect(desc.map(\.title) == ["Gran Turismo", "Bloodborne", "Journey", "Broken Sword", "Chrono Trigger"])
    }

    @Test func sortByTierRank() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        // Tiered games first (S before A), untiered last, ascending = best first.
        let ordered = try await store.gamesOnce(filter: LibraryFilter(sort: .tierRank, ascending: true))
        #expect(ordered.first?.title == "Bloodborne")     // S tier
        #expect(ordered[1].title == "Chrono Trigger")     // A tier
    }

    // MARK: - Row shape (no N+1)

    @Test func gridRowCarriesDenormalisedFacts() async throws {
        let store = try await TestDB.makeStore()
        _ = try await buildLibrary(store)
        let rows = try await store.gamesOnce(filter: LibraryFilter(searchText: "blood"))
        let row = try #require(rows.first)
        #expect(row.tierLetter == "S")
        #expect(row.tierColorHex?.hasPrefix("#") == true)
        #expect(row.owned && row.played)
        #expect(row.platformIDs == ["ps4"])
    }

    @Test func compilationMemberFlaggedInGrid() async throws {
        let store = try await TestDB.makeStore()
        let (_, members) = try await store.addCompilation(
            product: ProductDraft(platformID: "ps3"),
            members: [CompilationMemberDraft(title: "Sly 1", igdbID: 90, played: true, position: 0)])
        let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        let row = try #require(rows.first { $0.id == members[0].gameID })
        #expect(row.isCompilationMember)
    }
}
