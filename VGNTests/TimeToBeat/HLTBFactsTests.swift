import Foundation
import Testing
import GRDB
@testable import VGN

/// `timeToBeatFacts` now carries the game's stored `hltb_id` (D4) and its **effective
/// platforms** (D2, via `LibraryQuery.effectivePlatformsSQL`) so the fill flow can refresh
/// exactly and disambiguate by platform. `@MainActor` + GRDB ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct HLTBFactsTests {

    @Test(.timeLimit(.minutes(1)))
    func factsCarryEffectivePlatformsAndStoredID() async throws {
        let store = try await TestDB.makeStore()
        // A played-not-owned game with two played platforms.
        let id = try await store.addGame(GameDraft(
            title: "Bloodborne", platformIDs: ["ps4", "ps5"], owned: false, played: true)).gameID
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET hltb_id = 21262 WHERE id = ?", arguments: [id])
        }
        let facts = try await store.timeToBeatFacts(gameIDs: [id])
        let f = try #require(facts[id])
        #expect(f.hltbID == 21262)
        #expect(f.platformSlugSet == ["ps4", "ps5"])
    }

    @Test(.timeLimit(.minutes(1)))
    func factsPlatformsComeFromOwnedCopies() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Celeste", platformIDs: ["pc"], owned: true, played: true, format: .digital)).gameID
        let facts = try await store.timeToBeatFacts(gameIDs: [id])
        #expect(facts[id]?.platformSlugSet == ["pc"])
        #expect(facts[id]?.hltbID == nil)
    }
}
