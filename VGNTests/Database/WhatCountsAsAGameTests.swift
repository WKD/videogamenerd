import Foundation
import Testing
import GRDB
@testable import VGN

/// PLAN §5.1 "What counts as a game" review lists, both driven purely by a game's own cached
/// IGDB `game_type` (no request): **DLC & Expansions** (dlc/expansion/pack/season/update/mod)
/// and **Same Game, Two Entries** (a port whose parent is also in the library).
@Suite struct WhatCountsAsAGameTests {

    /// Insert a cached IGDB blob for `igdbID` with a `game_type` and optional `parent_game`.
    private func cache(_ store: LibraryStore, igdbID: Int64, gameType: Int, parent: Int64? = nil) async throws {
        var obj: [String: Any] = ["id": igdbID, "game_type": gameType]
        if let parent { obj["parent_game"] = parent }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        try await store.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO catalog_cache (igdb_id, json, fetched_at) VALUES (?, ?, ?)",
                           arguments: [igdbID, json, Date()])
        }
    }

    private func ids(_ store: LibraryStore, _ scope: SidebarSelection) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: LibraryFilter(scope: scope)).map(\.id))
    }

    // MARK: - D — DLC & Expansions

    @Test func dlcAndExpansionsMatchesTheRightTypes() async throws {
        let store = try await TestDB.makeStore()
        // In: dlc(1), expansion(2), mod(5), season(7), pack(13), update(14).
        var inIDs: [Int64] = []
        for (i, type) in [1, 2, 5, 7, 13, 14].enumerated() {
            let igdb = Int64(100 + i)
            let gid = try await store.addGame(GameDraft(title: "Add-on \(type)", igdbID: igdb, platformIDs: ["pc"], owned: true)).gameID
            try await cache(store, igdbID: igdb, gameType: type)
            inIDs.append(gid)
        }
        // Out: main(0), standalone_expansion(4), episode(6), remaster(9).
        for (i, type) in [0, 4, 6, 9].enumerated() {
            let igdb = Int64(200 + i)
            _ = try await store.addGame(GameDraft(title: "Game \(type)", igdbID: igdb, platformIDs: ["pc"], owned: true))
            try await cache(store, igdbID: igdb, gameType: type)
        }
        // A game with no cached type is never in.
        _ = try await store.addGame(GameDraft(title: "Uncached", igdbID: 999, platformIDs: ["pc"], owned: true))

        #expect(try await ids(store, .dlcAndExpansions) == Set(inIDs))
        // The sidebar count (composed into the single counts observation, like bundlesToExpand).
        let count = try await store.dbWriter.read { db in try LibraryQuery.fetchDLCAndExpansionsCount(db) }
        #expect(count == 6)
    }

    // MARK: - E — Same Game, Two Entries (port whose parent is also in the library)

    @Test func sameGameTwoEntriesFindsPortsWithParentInLibrary() async throws {
        let store = try await TestDB.makeStore()
        // Original (main game) in the library, igdb 500.
        let original = try await store.addGame(GameDraft(title: "Super Mario Galaxy", igdbID: 500, platformIDs: ["ps3"], owned: true)).gameID
        try await cache(store, igdbID: 500, gameType: 0)
        // A port (game_type 11) of 500, also in the library → a match.
        let port = try await store.addGame(GameDraft(title: "Super Mario Galaxy (Switch)", igdbID: 501, platformIDs: ["ps5"], owned: true)).gameID
        try await cache(store, igdbID: 501, gameType: 11, parent: 500)
        // A port whose parent is NOT in the library → not a match.
        let orphanPort = try await store.addGame(GameDraft(title: "Orphan Port", igdbID: 502, platformIDs: ["pc"], owned: true)).gameID
        try await cache(store, igdbID: 502, gameType: 11, parent: 88888)

        #expect(try await ids(store, .sameGameTwoEntries) == [port])
        let count = try await store.dbWriter.read { db in try LibraryQuery.fetchSameGameTwoEntriesCount(db) }
        #expect(count == 1)
        // The original is resolvable for the merge action; the orphan port has none.
        #expect(try await store.originalGameID(forPort: port) == original)
        #expect(try await store.originalGameID(forPort: orphanPort) == nil)
        // A non-port game returns no original.
        #expect(try await store.originalGameID(forPort: original) == nil)
    }

    /// The "Merge into the Original…" action reuses the existing reconcile merge: after it the
    /// port is gone and the original survives (spot-check the store merge with the resolved target).
    @Test func mergePortIntoOriginalFoldsTheEntries() async throws {
        let store = try await TestDB.makeStore()
        let original = try await store.addGame(GameDraft(title: "Myst", igdbID: 600, platformIDs: ["pc"], owned: true)).gameID
        try await cache(store, igdbID: 600, gameType: 0)
        let port = try await store.addGame(GameDraft(title: "Myst (2021)", igdbID: 601, platformIDs: ["ps4"], owned: true)).gameID
        try await cache(store, igdbID: 601, gameType: 11, parent: 600)

        let target = try #require(try await store.originalGameID(forPort: port))
        #expect(target == original)
        let inputs = try await store.mergeInputs(sourceGameID: port, targetGameID: target)
        _ = try await store.mergeGame(sourceGameID: port, into: target, decisions: inputs.decisions)

        let remaining = Set(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).map(\.id))
        #expect(remaining.contains(original))
        #expect(remaining.contains(port) == false)
        // The original now shows both platforms (copies folded in).
        let g = try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == original })
        #expect(Set(g.platformIDs) == ["pc", "ps4"])
    }
}
