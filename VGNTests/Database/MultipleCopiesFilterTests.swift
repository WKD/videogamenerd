import Foundation
import Testing
import GRDB
@testable import VGN

/// The "Owns multiple copies" toolbar facet (owner request 2026-09-19): a game
/// matches only when it has ≥ 2 owned products (copies/formats), and it ANDs across
/// kinds like any other facet (PLAN §8).
@Suite struct MultipleCopiesFilterTests {

    private func ids(_ store: LibraryStore, _ f: LibraryFilter) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: f).map(\.id))
    }

    @Test func matchesOnlyGamesWithTwoOrMoreCopies() async throws {
        let store = try await TestDB.makeStore()
        // One copy → excluded.
        let single = try await store.addGame(GameDraft(title: "Single", igdbID: 1,
                                                       platformIDs: ["pc"], owned: true))
        // Two copies (physical on ps4 + digital on ps5) → matches.
        let dbl = try await store.addGame(GameDraft(title: "Double", igdbID: 2,
                                                    platformIDs: ["ps4"], owned: true))
        _ = try await store.addCopy(gameID: dbl.gameID, platformID: "ps5", format: .digital)
        // Played-only, no copies → excluded.
        let none = try await store.addGame(GameDraft(title: "None", igdbID: 3,
                                                     platformIDs: ["pc"], owned: false, played: true))

        #expect(try await ids(store, LibraryFilter(multipleCopies: true, scope: .all)) == [dbl.gameID])
        // Sanity: without the facet all three are present.
        #expect(try await ids(store, LibraryFilter(scope: .all)) == [single.gameID, dbl.gameID, none.gameID])

        // ANDs across kinds (multiple copies AND a platform facet).
        var f = LibraryFilter(multipleCopies: true, scope: .all)
        f.platforms = ["ps5"]
        #expect(try await ids(store, f) == [dbl.gameID])
        // A platform the multi-copy game is NOT on → empty.
        f.platforms = ["snes"]
        #expect(try await ids(store, f).isEmpty)
    }

    @Test func threeCopiesStillMatchesAndFacetIsInactiveByDefault() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "Triple", igdbID: 1,
                                                  platformIDs: ["pc"], owned: true))
        _ = try await store.addCopy(gameID: g.gameID, platformID: "ps4", format: .digital)
        _ = try await store.addCopy(gameID: g.gameID, platformID: "ps5", format: .physical)
        #expect(try await ids(store, LibraryFilter(multipleCopies: true, scope: .all)) == [g.gameID])
        // Off by default — the facet doesn't constrain a plain filter.
        #expect(LibraryFilter(scope: .all).multipleCopies == false)
        #expect(try await ids(store, LibraryFilter(scope: .all)).count == 1)
    }
}
