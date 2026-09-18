import Foundation
import Testing
import GRDB
@testable import VGN

@Suite struct LibraryStoreWriteTests {

    // MARK: - Add + ownership

    @Test func addOwnedGameCreatesProduct() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Bloodborne", platformIDs: ["ps4"], owned: true))
        guard case let .created(id) = outcome else { Issue.record("expected created"); return }
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.owned)
        #expect(detail.copies.count == 1)
        #expect(detail.copies.first?.platformID == "ps4")
        #expect(detail.copies.first?.format == .physical)
    }

    @Test func playedOnlyGameHasNoProduct() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Broken Sword", platformIDs: ["pc"], owned: false, played: true))
        let detail = try #require(try await store.gameDetail(id: outcome.gameID))
        #expect(detail.played)
        #expect(!detail.owned)
        #expect(detail.copies.isEmpty)
        #expect(detail.platformIDs == ["pc"])
    }

    @Test func tierOnAddImpliesPlayed() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Elden Ring", platformIDs: ["ps5"], owned: true, tierID: 1))
        let detail = try #require(try await store.gameDetail(id: outcome.gameID))
        #expect(detail.played)
        #expect(detail.tierID == 1)
    }

    // MARK: - IGDB dedupe

    @Test func igdbDedupeReusesGameAddsSecondProduct() async throws {
        let store = try await TestDB.makeStore()
        let first = try await store.addGame(
            GameDraft(title: "Elden Ring", igdbID: 1234, platformIDs: ["ps4"], owned: true))
        let second = try await store.addGame(
            GameDraft(title: "Elden Ring", igdbID: 1234, platformIDs: ["ps5"], owned: true))

        #expect(first.gameID == second.gameID)
        if case .addedCopy = second {} else { Issue.record("expected addedCopy, got \(second)") }

        let detail = try #require(try await store.gameDetail(id: first.gameID))
        #expect(detail.copies.count == 2)
        #expect(Set(detail.copies.map(\.platformID)) == ["ps4", "ps5"])
        #expect(detail.platformIDs == ["ps4", "ps5"])
    }

    @Test func reAddingSameCopyIsAlreadyPresent() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "Elden Ring", igdbID: 1, platformIDs: ["ps4"], owned: true))
        let again = try await store.addGame(GameDraft(title: "Elden Ring", igdbID: 1, platformIDs: ["ps4"], owned: true))
        if case .alreadyPresent = again {} else { Issue.record("expected alreadyPresent, got \(again)") }
        let detail = try #require(try await store.gameDetail(id: again.gameID))
        #expect(detail.copies.count == 1)
    }

    // MARK: - Invariant 1: orphan handling

    @Test func unplayingOwnedGameKeepsIt() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Halo", platformIDs: ["ps4"], owned: true, played: true))
        let result = try await store.setPlayed([outcome.gameID], false)
        #expect(result == .ok)
        let detail = try #require(try await store.gameDetail(id: outcome.gameID))
        #expect(!detail.played)
        #expect(detail.owned)      // still owned = still exists (backlog)
    }

    @Test func unplayingUnownedGameWouldOrphanThenDeletesOnConfirm() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Journey", platformIDs: ["pc"], owned: false, played: true))
        let id = outcome.gameID

        // Without confirmation: no change, reports the orphan.
        let refused = try await store.setPlayed([id], false)
        #expect(refused == .wouldOrphan([id]))
        let stillThere = try await store.gameDetail(id: id)
        #expect(stillThere?.played == true)   // rolled back

        // With confirmation: game is deleted.
        let confirmed = try await store.setPlayed([id], false, confirmOrphanDelete: true)
        #expect(confirmed == .ok)
        #expect(try await store.gameDetail(id: id) == nil)
    }

    @Test func removingLastProductWouldOrphanUnplayedGame() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Gran Turismo", platformIDs: ["ps4"], owned: true, played: false))
        let id = outcome.gameID
        let productID = try #require(try await store.gameDetail(id: id)?.copies.first?.productID)

        let refused = try await store.removeProduct(productID)
        #expect(refused == .wouldOrphan([id]))
        #expect(try await store.gameDetail(id: id) != nil)   // rolled back

        let confirmed = try await store.removeProduct(productID, confirmOrphanDelete: true)
        #expect(confirmed == .ok)
        #expect(try await store.gameDetail(id: id) == nil)
    }

    @Test func removingProductFromPlayedGameJustUnowns() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Celeste", platformIDs: ["pc"], owned: true, played: true))
        let id = outcome.gameID
        let productID = try #require(try await store.gameDetail(id: id)?.copies.first?.productID)
        let result = try await store.removeProduct(productID)
        #expect(result == .ok)
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(!detail.owned)
        #expect(detail.played)     // still played = still exists
    }

    // MARK: - Invariant 2: only played games carry tier/rank

    @Test func unplayingClearsTierAndRank() async throws {
        let store = try await TestDB.makeStore()
        let outcome = try await store.addGame(
            GameDraft(title: "Dark Souls", platformIDs: ["ps4"], owned: true, played: true, tierID: 2))
        let id = outcome.gameID
        // Simulate a fine-rank key having been assigned (Wave 3 RankStore).
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET rank_key = 5000 WHERE id = ?", arguments: [id])
        }
        _ = try await store.setPlayed([id], false)
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.tierID == nil)
        #expect(detail.rankKey == nil)
    }

    @Test func setTierSkipsUnplayedGames() async throws {
        let store = try await TestDB.makeStore()
        let played = try await store.addGame(
            GameDraft(title: "Hades", platformIDs: ["pc"], owned: true, played: true)).gameID
        let unplayed = try await store.addGame(
            GameDraft(title: "Backlog Game", platformIDs: ["pc"], owned: true, played: false)).gameID

        let outcome = try await store.setTier([played, unplayed], tierID: 1)
        #expect(outcome.applied == [played])
        #expect(outcome.skippedUnplayed == [unplayed])
        #expect(try await store.gameDetail(id: unplayed)?.tierID == nil)
        #expect(try await store.gameDetail(id: played)?.tierID == 1)
    }

    @Test func setTierClearsRankKeyToUnplaced() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Hollow Knight", platformIDs: ["pc"], owned: true, played: true, tierID: 1)).gameID
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET rank_key = 100 WHERE id = ?", arguments: [id])
        }
        _ = try await store.setTier([id], tierID: 3)   // move tier
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.tierID == 3)
        #expect(detail.rankKey == nil)                 // unplaced again
    }

    // MARK: - Compilations (all-or-nothing ownership)

    @Test func compilationOneProductManyGames() async throws {
        let store = try await TestDB.makeStore()
        let (productID, members) = try await store.addCompilation(
            product: ProductDraft(title: "MGS Legacy Collection", platformID: "ps3", source: .manual),
            members: [
                CompilationMemberDraft(title: "MGS", igdbID: 10, played: true, position: 0),
                CompilationMemberDraft(title: "MGS2", igdbID: 11, position: 1),
                CompilationMemberDraft(title: "MGS3", igdbID: 12, position: 2),
            ])
        #expect(members.count == 3)

        for outcome in members {
            let detail = try #require(try await store.gameDetail(id: outcome.gameID))
            #expect(detail.owned)
            #expect(detail.isCompilationMember)
            #expect(detail.copies.first?.title == "MGS Legacy Collection")
            #expect(detail.copies.first?.memberCount == 3)
        }
        // Removing the product un-owns all members at once (all-or-nothing).
        // Two members are unplayed → both would orphan; MGS is played → kept.
        let refused = try await store.removeProduct(productID)
        guard case let .wouldOrphan(ids) = refused else { Issue.record("expected wouldOrphan"); return }
        #expect(ids.count == 2)
        // Confirm: unplayed members deleted, played member survives un-owned.
        let confirmed = try await store.removeProduct(productID, confirmOrphanDelete: true)
        #expect(confirmed == .ok)
        let survivor = members.first { $0.gameID == members[0].gameID }!
        let detail = try #require(try await store.gameDetail(id: survivor.gameID))
        #expect(!detail.owned)
        #expect(detail.played)
    }

    @Test func compilationReusesExistingGameByIGDB() async throws {
        let store = try await TestDB.makeStore()
        let standalone = try await store.addGame(
            GameDraft(title: "ICO", igdbID: 500, platformIDs: ["ps2"], owned: true, played: true)).gameID
        let (_, members) = try await store.addCompilation(
            product: ProductDraft(platformID: "ps3"),
            members: [
                CompilationMemberDraft(title: "ICO", igdbID: 500, position: 0),
                CompilationMemberDraft(title: "Shadow of the Colossus", igdbID: 501, position: 1),
            ])
        #expect(members.first?.gameID == standalone)   // reused
        let detail = try #require(try await store.gameDetail(id: standalone))
        #expect(detail.copies.count == 2)              // ps2 standalone + ps3 compilation
    }

    @Test func removeCompilationMemberUnownsJustThatMember() async throws {
        let store = try await TestDB.makeStore()
        let (productID, members) = try await store.addCompilation(
            product: ProductDraft(platformID: "ps3"),
            members: [
                CompilationMemberDraft(title: "A", igdbID: 1, played: true, position: 0),
                CompilationMemberDraft(title: "B", igdbID: 2, played: true, position: 1),
            ])
        let result = try await store.removeCompilationMember(productID: productID, gameID: members[1].gameID)
        #expect(result == .ok)
        #expect(try await store.gameDetail(id: members[1].gameID)?.owned == false)
        #expect(try await store.gameDetail(id: members[0].gameID)?.owned == true)
    }

    // MARK: - Metadata + status + playtime

    @Test func updateMetadataWritesGenresAltTitlesAndTTB() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "The Witcher 3", platformIDs: ["pc"], owned: true, played: true)).gameID
        try await store.updateMetadata(gameID: id, MetadataPatch(
            summary: "A monster hunter's tale.",
            releaseDate: nil, year: 2015,
            altTitles: ["Wiedźmin 3"],
            genres: ["RPG", "Action"],
            igdbCoverImageID: "abc123",
            ttbNormallyS: 180_000))
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.year == 2015)
        #expect(Set(detail.genres) == ["Action", "RPG"])
        #expect(detail.igdbCoverImageID == "abc123")
        #expect(detail.ttbNormallyS == 180_000)
        #expect(detail.summary == "A monster hunter's tale.")
    }

    @Test func setStatusAndPlaytime() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(
            GameDraft(title: "Sekiro", platformIDs: ["ps4"], owned: true, played: true)).gameID
        try await store.setStatus([id], .completed)
        try await store.setMyPlaytime(gameID: id, seconds: 144_000)
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.status == .completed)
        #expect(detail.myPlaytimeS == 144_000)
        #expect(detail.effectivePlaytimeS == 144_000)
    }

    @Test func appStateRoundTrips() async throws {
        let store = try await TestDB.makeStore()
        struct Session: Codable, Equatable { var gameID: Int64; var step: Int }
        let session = Session(gameID: 42, step: 3)
        try await store.saveAppState(key: "ranking.session", session)
        let loaded = try await store.loadAppState(key: "ranking.session", as: Session.self)
        #expect(loaded == session)
        // Overwrites in place.
        try await store.saveAppState(key: "ranking.session", Session(gameID: 42, step: 4))
        #expect(try await store.loadAppState(key: "ranking.session", as: Session.self)?.step == 4)
    }
}
