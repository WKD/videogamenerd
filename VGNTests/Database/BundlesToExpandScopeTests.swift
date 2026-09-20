import Foundation
import GRDB
import Testing
@testable import VGN

/// The "Bundles to Expand" smart-list grid scope (PLAN §5.1 / §8, wave 16): the grid, the count
/// and ``LibraryStore/bundleExpansionCandidates()`` all use ONE candidate rule, so the grid
/// returns exactly the candidates — a bundle-looking lone single is in; an ordinary game, a
/// compilation member, and a dismissed game are out — and the list shrinks after an expansion or
/// a dismissal. No network; each test uses its own in-memory DB.
@Suite(.serialized)
struct BundlesToExpandScopeTests {

    @discardableResult
    private func addLoneSingle(_ store: LibraryStore, title: String, igdbID: Int64?) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title))
            try g.insert(db)
            let gid = g.id!
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source) VALUES ('ps3', 'single', 'physical', 'manual')
                """)
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gid])
            try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, 'ps3', 0)",
                           arguments: [gid])
            return gid
        }
    }

    /// A compilation product with two member games; returns the (bundle-looking) member's id.
    @discardableResult
    private func addCompilationMember(_ store: LibraryStore, memberTitle: String) async throws -> Int64 {
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, title)
                VALUES ('ps3', 'compilation', 'physical', 'manual', 'A Compilation')
                """)
            let pid = db.lastInsertedRowID
            var member = GameRecord(title: memberTitle, sortTitle: SortTitle.make(from: memberTitle))
            try member.insert(db)
            let memberID = member.id!
            var other = GameRecord(title: "Plain Member", sortTitle: SortTitle.make(from: "Plain Member"))
            try other.insert(db)
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, memberID])
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 1)",
                           arguments: [pid, other.id!])
            return memberID
        }
    }

    private func candidateIDs(_ store: LibraryStore) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: LibraryFilter(scope: .bundlesToExpand)).map(\.id))
    }

    @Test(.timeLimit(.minutes(1)))
    func gridScopeReturnsExactlyTheCandidates() async throws {
        let store = try await TestDB.makeStore()
        let trilogy = try await addLoneSingle(store, title: "The Tomb Raider Trilogy", igdbID: 10)
        let collection = try await addLoneSingle(store, title: "God of War Collection", igdbID: 12)
        // A series entry: keyword-before-colon + a specific subtitle → a single, not a bundle (W19 2B).
        _ = try await addLoneSingle(
            store, title: "The Dark Pictures Anthology: House of Ashes", igdbID: 11)
        _ = try await addLoneSingle(store, title: "Bloodborne", igdbID: 20)           // ordinary
        _ = try await addCompilationMember(store, memberTitle: "Some Trilogy")        // already a member

        let ids = try await candidateIDs(store)
        #expect(ids == [trilogy, collection])

        // The grid scope and the async candidate API agree (one rule).
        let apiIDs = Set(try await store.bundleExpansionCandidates().map(\.gameID))
        #expect(apiIDs == ids)
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissingAGameRemovesItFromTheGrid() async throws {
        let store = try await TestDB.makeStore()
        let collection = try await addLoneSingle(
            store, title: "God of War Collection", igdbID: 12)
        #expect(try await candidateIDs(store).contains(collection))   // included until dismissed

        try await store.dismissBundleCandidate(gameID: collection)
        #expect(!(try await candidateIDs(store).contains(collection)))
    }

    @Test(.timeLimit(.minutes(1)))
    func listShrinksAfterExpandBundle() async throws {
        let store = try await TestDB.makeStore()
        let placeholder = try await addLoneSingle(store, title: "God of War Collection", igdbID: 500)
        #expect(try await candidateIDs(store) == [placeholder])

        _ = try await store.expandBundle(
            gameID: placeholder, bundleTitle: "God of War Collection",
            members: [CompilationMemberDraft(title: "God of War", igdbID: 1, position: 0),
                      CompilationMemberDraft(title: "God of War II", igdbID: 2, position: 1)])
        // The placeholder was expanded (and deleted); its members don't look like bundles.
        #expect(try await candidateIDs(store).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func candidateCostAt2000GamesIsPrintedNotAsserted() async throws {
        // The candidate rule fetches id/title over the whole library and filters in Swift (the
        // title heuristic isn't cheap SQL). Print the cost at 2 000 games — never a wall-clock
        // assertion (flakes under parallel load).
        let store = try await TestDB.makeStore()
        try await store.dbWriter.write { db in
            for i in 0..<2_000 {
                let title = i % 50 == 0 ? "Series \(i) Collection" : "Game \(i)"
                var g = GameRecord(title: title, sortTitle: SortTitle.make(from: title))
                try g.insert(db)
            }
        }
        let start = Date()
        let count = try await store.dbReader.read { try LibraryStore.fetchBundleExpansionCandidates($0).count }
        let ms = Date().timeIntervalSince(start) * 1000
        print("[BundlesToExpand] candidate scan over 2000 games: \(count) candidates in \(String(format: "%.1f", ms)) ms")
        #expect(count == 40)   // every 50th title looks like a bundle
    }
}
