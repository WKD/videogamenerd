import Foundation
import GRDB
import Testing
@testable import VGN

/// The "Bundles to Expand" candidate rule after W19 part 2B (PLAN §5.1): the title heuristic
/// no longer treats a "<keyword>: <subtitle>" series entry as a bundle, and a LINKED game's own
/// cached IGDB `game_type` (read from `catalog_cache`, zero requests) is authoritative — a
/// cached bundle/pack is in even without a title hint, a cached non-bundle is out even when the
/// title matches. No cached type / unrecognised type → today's title-or-typed fallback. The
/// list, grid scope and count share one function, so they always agree.
@Suite(.serialized)
struct BundleCandidateTypeTests {

    // MARK: Title heuristic table

    @Test(arguments: [
        ("The Dark Pictures Anthology: Man of Medan", false),   // series entry, not a bundle
        ("The Dark Pictures Anthology: House of Ashes", false),
        ("LEGO Harry Potter Collection: Years 1-4", false),     // part-of-a-collection single
        ("8-bit Adventure Anthology: Volume I", true),          // volume marker → still a bundle
        ("Mega Man Legacy Collection Vol. 2", true),
        ("The Tomb Raider Trilogy", true),
        ("God of War Collection", true),
        ("Halo: The Master Chief Collection", true),            // keyword only in the subtitle
        ("Metal Gear Solid: The Legacy Collection", true),
        ("The Orange Box", true),
        ("Jak and Daxter Collection", true),
        ("Persona 5", false),
        ("Castlevania: Symphony of the Night", false),          // no bundle keyword at all
        ("Ratchet & Clank", false),
    ])
    func titleHeuristic(_ title: String, _ expected: Bool) {
        #expect(LibraryStore.looksLikeBundleTitle(title) == expected)
    }

    // MARK: Cached-type override

    @discardableResult
    private func addLoneSingle(_ store: LibraryStore, title: String, igdbID: Int64) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title))
            try g.insert(db)
            let gid = g.id!
            try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('ps4','single','physical','manual')")
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gid])
            try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, 'ps4', 0)",
                           arguments: [gid])
            return gid
        }
    }

    private func setCachedType(_ store: LibraryStore, igdbID: Int64, gameType: Int) async throws {
        try await store.dbWriter.write { db in
            let json = "{\"id\":\(igdbID),\"name\":\"x\",\"game_type\":\(gameType)}"
            try db.execute(sql: "INSERT INTO catalog_cache (igdb_id, json, fetched_at) VALUES (?, ?, ?)",
                           arguments: [igdbID, json, Date()])
        }
    }

    private func candidateIDs(_ store: LibraryStore) async throws -> Set<Int64> {
        Set(try await store.bundleExpansionCandidates().map(\.gameID))
    }

    @Test(.timeLimit(.minutes(1)))
    func cachedBundleTypeMakesANonBundleTitleACandidate() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addLoneSingle(store, title: "Castlevania Requiem", igdbID: 100)   // no keyword
        #expect(!(try await candidateIDs(store).contains(id)))             // title alone → out
        try await setCachedType(store, igdbID: 100, gameType: IGDBGameType.bundle.rawValue)
        #expect(try await candidateIDs(store).contains(id))               // cached bundle type → in
    }

    @Test(.timeLimit(.minutes(1)))
    func cachedNonBundleTypeExcludesABundleTitle() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addLoneSingle(store, title: "God of War Collection", igdbID: 200)
        #expect(try await candidateIDs(store).contains(id))               // title → in
        try await setCachedType(store, igdbID: 200, gameType: IGDBGameType.mainGame.rawValue)
        #expect(!(try await candidateIDs(store).contains(id)))            // cached main-game → out
    }

    @Test(.timeLimit(.minutes(1)))
    func noCacheFallsBackToTitle() async throws {
        let store = try await TestDB.makeStore()
        let bundle = try await addLoneSingle(store, title: "The Tomb Raider Trilogy", igdbID: 300)
        let single = try await addLoneSingle(store, title: "Bloodborne", igdbID: 301)
        let ids = try await candidateIDs(store)
        #expect(ids.contains(bundle))
        #expect(!ids.contains(single))
    }

    @Test(.timeLimit(.minutes(1)))
    func unrecognisedCachedTypeFallsBackToTitle() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addLoneSingle(store, title: "God of War Collection", igdbID: 400)
        try await setCachedType(store, igdbID: 400, gameType: 99)         // unknown → fall back
        #expect(try await candidateIDs(store).contains(id))              // title heuristic still applies
    }

    @Test(.timeLimit(.minutes(1)))
    func dismissedStaysExcludedEvenWithCachedBundleType() async throws {
        let store = try await TestDB.makeStore()
        let id = try await addLoneSingle(store, title: "Castlevania Requiem", igdbID: 500)
        try await setCachedType(store, igdbID: 500, gameType: IGDBGameType.bundle.rawValue)
        #expect(try await candidateIDs(store).contains(id))
        try await store.dismissBundleCandidate(gameID: id)
        #expect(!(try await candidateIDs(store).contains(id)))
    }

    @Test(.timeLimit(.minutes(1)))
    func listGridAndCountAgreeWithCachedOverride() async throws {
        let store = try await TestDB.makeStore()
        let typed = try await addLoneSingle(store, title: "Castlevania Requiem", igdbID: 600)  // in via cache
        try await setCachedType(store, igdbID: 600, gameType: IGDBGameType.bundle.rawValue)
        let overridden = try await addLoneSingle(store, title: "God of War Collection", igdbID: 601)
        try await setCachedType(store, igdbID: 601, gameType: IGDBGameType.mainGame.rawValue)  // out via cache
        _ = overridden

        let list = Set(try await store.bundleExpansionCandidates().map(\.gameID))
        let grid = Set(try await store.gamesOnce(filter: LibraryFilter(scope: .bundlesToExpand)).map(\.id))
        let count = try await store.dbReader.read { try LibraryStore.fetchBundleExpansionCandidates($0).count }
        #expect(list == grid)
        #expect(list == [typed])
        #expect(count == 1)
    }
}
