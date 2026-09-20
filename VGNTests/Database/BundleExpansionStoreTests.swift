import Foundation
import GRDB
import Testing
@testable import VGN

/// Store-side bundle expansion (PLAN §5.1 repair / reconcile): a placeholder game linked to
/// an IGDB bundle becomes a compilation of its member games — deduped against the library,
/// play data moved to a chosen member, the empty placeholder deleted, all reversible. No
/// network; each test uses its own in-memory DB.
struct BundleExpansionStoreTests {

    @discardableResult
    private func addGame(
        _ store: LibraryStore, title: String, igdbID: Int64? = nil, played: Bool = false,
        status: String? = nil, tierID: Int64? = nil, rankKey: Int64? = nil, myPlaytimeS: Int? = nil
    ) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title),
                               played: played, status: status, tierID: tierID, rankKey: rankKey,
                               myPlaytimeS: myPlaytimeS)
            try g.insert(db)
            return g.id!
        }
    }

    @discardableResult
    private func addProduct(_ store: LibraryStore, gameID: Int64, platform: String,
                            format: ProductFormat = .physical) async throws -> Int64 {
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source) VALUES (?, 'single', ?, 'manual')
                """, arguments: [platform, format.rawValue])
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gameID])
            try db.execute(sql: """
                INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, ?, 0)
                ON CONFLICT(game_id, platform_id) DO NOTHING
                """, arguments: [gameID, platform])
            return pid
        }
    }

    private func member(_ igdbID: Int64, _ title: String, position: Int) -> CompilationMemberDraft {
        CompilationMemberDraft(title: title, igdbID: igdbID, position: position)
    }
    private func exists(_ store: LibraryStore, _ id: Int64) async throws -> Bool {
        try await store.dbReader.read {
            try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [id]) ?? false
        }
    }
    private func game(_ store: LibraryStore, _ id: Int64) async throws -> GameRecord? {
        try await store.dbReader.read { try GameRecord.fetchOne($0, key: id) }
    }
    private func gameByIGDB(_ store: LibraryStore, _ igdbID: Int64) async throws -> GameRecord? {
        try await store.dbReader.read {
            try GameRecord.filter(GameRecord.Columns.igdbID == igdbID).fetchOne($0)
        }
    }
    private func count(_ store: LibraryStore, _ sql: String) async throws -> Int {
        try await store.dbReader.read { try Int.fetchOne($0, sql: sql) ?? -1 }
    }
    private func invariantsHold(_ store: LibraryStore) async throws -> Bool {
        let snap = try await store.dbReader.read { try RankingStore.loadSnapshot($0) }
        return Consistency.checkInvariants(snap).isEmpty
    }

    // MARK: - Tests

    @Test func unplayedPlaceholderDeletedMembersCreatedAndDeduped() async throws {
        let store = try await TestDB.makeStore()
        // A pre-existing library game that is one of the members (igdb 1).
        let existing = try await addGame(store, title: "God of War", igdbID: 1)
        try await addProduct(store, gameID: existing, platform: "ps3")
        // The placeholder: "God of War Collection" (igdb 500), owned on ps3, no play data.
        let placeholder = try await addGame(store, title: "God of War Collection", igdbID: 500)
        try await addProduct(store, gameID: placeholder, platform: "ps3")

        let result = try await store.expandBundle(
            gameID: placeholder, bundleTitle: "God of War Collection",
            members: [member(1, "God of War", position: 0), member(2, "God of War II", position: 1)])

        // Placeholder gone; one compilation with two members; the existing member not duplicated.
        let placeholderGone = try await exists(store, placeholder)
        #expect(!placeholderGone)
        let dup = try await count(store, "SELECT COUNT(*) FROM games WHERE igdb_id = 1")
        #expect(dup == 1)
        let comps = try await count(store, "SELECT COUNT(*) FROM products WHERE kind = 'compilation'")
        #expect(comps == 1)
        #expect(result.memberGameIDs.count == 2)
        #expect(result.createdCount == 1)   // only "God of War II" was new
        let ok = try await invariantsHold(store)
        #expect(ok)
    }

    @Test func playedPlaceholderDataMovesToChosenMember() async throws {
        let store = try await TestDB.makeStore()
        // A played, ranked placeholder with playtime.
        let placeholder = try await addGame(
            store, title: "The Tomb Raider Trilogy", igdbID: 500, played: true,
            status: PlayStatus.completed.rawValue, tierID: 1, rankKey: 1_000, myPlaytimeS: 7_200)
        try await addProduct(store, gameID: placeholder, platform: "ps3")

        let members = [member(1, "Tomb Raider: Legend", position: 0),
                       member(2, "Tomb Raider: Anniversary", position: 1)]
        _ = try await store.expandBundle(
            gameID: placeholder, bundleTitle: "The Tomb Raider Trilogy",
            members: members, playDataTargetIndex: 0)

        #expect(try await exists(store, placeholder) == false)
        let target = try #require(try await gameByIGDB(store, 1))     // the chosen member (index 0)
        #expect(target.played)
        #expect(target.tierID == 1)
        #expect(target.rankKey == 1_000)
        #expect(target.myPlaytimeS == 7_200)
        #expect(target.status == PlayStatus.completed.rawValue)
        // The other member is owned-not-played.
        let other = try #require(try await gameByIGDB(store, 2))
        #expect(!other.played)
        #expect(other.tierID == nil)
        let ok = try await invariantsHold(store)
        #expect(ok)
    }

    @Test func undoRestoresThePlaceholderAndDeletesNewMembers() async throws {
        let store = try await TestDB.makeStore()
        let placeholder = try await addGame(
            store, title: "The Bard's Tale Trilogy", igdbID: 500, played: true,
            tierID: 2, rankKey: 500, myPlaytimeS: 3_600)
        try await addProduct(store, gameID: placeholder, platform: "pc", format: .digital)

        let gamesBefore = try await count(store, "SELECT COUNT(*) FROM games")
        let productsBefore = try await count(store, "SELECT COUNT(*) FROM products")

        let result = try await store.expandBundle(
            gameID: placeholder, bundleTitle: "The Bard's Tale Trilogy",
            members: [member(1, "The Bard's Tale I", position: 0),
                      member(2, "The Bard's Tale II", position: 1)],
            playDataTargetIndex: 0)
        #expect(try await exists(store, placeholder) == false)

        // Undo restores the placeholder verbatim and removes the created members.
        try await store.restoreBundleExpansion(result.undo)
        let restored = try #require(try await game(store, placeholder))
        #expect(restored.played)
        #expect(restored.tierID == 2)
        #expect(restored.rankKey == 500)
        #expect(restored.myPlaytimeS == 3_600)
        let gamesAfter = try await count(store, "SELECT COUNT(*) FROM games")
        let productsAfter = try await count(store, "SELECT COUNT(*) FROM products")
        #expect(gamesAfter == gamesBefore)
        #expect(productsAfter == productsBefore)
        // The placeholder's product is a single again.
        let comps = try await count(store, "SELECT COUNT(*) FROM products WHERE kind = 'compilation'")
        #expect(comps == 0)
        let ok = try await invariantsHold(store)
        #expect(ok)
    }

    @Test func emptyMembersThrows() async throws {
        let store = try await TestDB.makeStore()
        let g = try await addGame(store, title: "Not A Bundle", igdbID: 500)
        try await addProduct(store, gameID: g, platform: "ps3")
        await #expect(throws: BundleExpansionError.self) {
            _ = try await store.expandBundle(gameID: g, bundleTitle: "x", members: [])
        }
    }

    @Test func candidateHeuristicMatchesBundleWords() {
        #expect(LibraryStore.looksLikeBundleTitle("The Tomb Raider Trilogy"))
        #expect(LibraryStore.looksLikeBundleTitle("God of War Collection"))
        #expect(LibraryStore.looksLikeBundleTitle("Metroid Prime: Trilogy"))
        #expect(LibraryStore.looksLikeBundleTitle("Sonic Mega Collection"))
        #expect(LibraryStore.looksLikeBundleTitle("3-in-1 Fun Pack"))
        // Conservative: an ordinary game is not a candidate.
        #expect(!LibraryStore.looksLikeBundleTitle("Bloodborne"))
        #expect(!LibraryStore.looksLikeBundleTitle("Evolution Worlds"))
    }

    @Test func candidatesListFindsUnexpandedBundles() async throws {
        let store = try await TestDB.makeStore()
        let bundle = try await addGame(store, title: "God of War Collection", igdbID: 500)
        try await addProduct(store, gameID: bundle, platform: "ps3")
        _ = try await addGame(store, title: "Bloodborne", igdbID: 600)
        let candidates = try await store.bundleExpansionCandidates()
        #expect(candidates.contains { $0.gameID == bundle })
        #expect(!candidates.contains { $0.title == "Bloodborne" })
    }
}
