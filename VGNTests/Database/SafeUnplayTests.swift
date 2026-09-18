import Foundation
import Testing
import GRDB
@testable import VGN

/// Triage-safe un-play (PLAN §7 follow-up): the store operation never prompts,
/// owned → Backlog, not owned → distinct `.notOwned` (no change).
@Suite struct SafeUnplayTests {

    @Test func ownedGameBecomesBacklogNoPrompt() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(
            title: "Bloodborne", igdbID: 1, platformIDs: ["ps4"],
            owned: true, played: true, tierID: 1, status: .completed))
        let outcome = try await store.markNotPlayed(g.gameID)
        #expect(outcome == .becameBacklog)
        let detail = try #require(try await store.gameDetail(id: g.gameID))
        #expect(!detail.played)
        #expect(detail.owned)              // still owned → backlog
        #expect(detail.tierID == nil)      // tier + rank + status cleared
        #expect(detail.status == nil)
        #expect(detail.owned && !detail.played)   // = Backlog
    }

    @Test func notOwnedGameReturnsNotOwnedAndDoesNotChange() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(
            title: "Broken Sword", igdbID: 2, platformIDs: ["pc"], owned: false, played: true, tierID: 2))
        let outcome = try await store.markNotPlayed(g.gameID)
        #expect(outcome == .notOwned)
        // No change: still played and tiered (the game was NOT deleted).
        let detail = try #require(try await store.gameDetail(id: g.gameID))
        #expect(detail.played)
        #expect(detail.tierID == 2)
    }

    @Test func missingGameReturnsNotFound() async throws {
        let store = try await TestDB.makeStore()
        #expect(try await store.markNotPlayed(999) == .notFound)
    }
}
