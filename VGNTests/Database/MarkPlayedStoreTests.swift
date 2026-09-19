import Foundation
import Testing
import GRDB
@testable import VGN

/// Tests for ``LibraryStore/markPlayed(_:status:)`` — the additive bulk "Mark
/// Played As" write (PLAN §8, owner request 2026-09-19).
@Suite struct MarkPlayedStoreTests {

    /// A backlog game (owned, not played) to mark.
    private func backlog(_ store: LibraryStore, _ title: String) async throws -> Int64 {
        try await store.addGame(GameDraft(title: title, platformIDs: ["ps4"], owned: true)).gameID
    }

    @Test func markPlayedSetsPlayedForAll() async throws {
        let store = try await TestDB.makeStore()
        let a = try await backlog(store, "A")
        let b = try await backlog(store, "B")

        try await store.markPlayed([a, b], status: nil)

        #expect(try await store.gameDetail(id: a)?.played == true)
        #expect(try await store.gameDetail(id: b)?.played == true)
        // No status requested → none set.
        #expect(try await store.gameDetail(id: a)?.status == nil)
    }

    @Test func markWithStatusSetsPlayedAndStatus() async throws {
        let store = try await TestDB.makeStore()
        let a = try await backlog(store, "A")

        try await store.markPlayed([a], status: .finished)

        let detail = try #require(try await store.gameDetail(id: a))
        #expect(detail.played)
        #expect(detail.status == .finished)
    }

    @Test func plainPlayedLeavesExistingStatusAlone() async throws {
        let store = try await TestDB.makeStore()
        let a = try await backlog(store, "A")
        try await store.markPlayed([a], status: .completed)   // now played + 100%

        // A plain "Played" mark must not wipe the status.
        try await store.markPlayed([a], status: nil)

        let detail = try #require(try await store.gameDetail(id: a))
        #expect(detail.played)
        #expect(detail.status == .completed)
    }

    @Test func statusMarkOverwritesPriorStatus() async throws {
        let store = try await TestDB.makeStore()
        let a = try await backlog(store, "A")
        try await store.markPlayed([a], status: .playing)
        try await store.markPlayed([a], status: .abandoned)
        #expect(try await store.gameDetail(id: a)?.status == .abandoned)
    }

    @Test func alreadyPlayedGameJustGetsStatus() async throws {
        let store = try await TestDB.makeStore()
        // Played-only game (no product) — marking must not create one.
        let a = try await store.addGame(
            GameDraft(title: "Ico", platformIDs: ["ps2"], played: true)).gameID

        try await store.markPlayed([a], status: .finished)

        let detail = try #require(try await store.gameDetail(id: a))
        #expect(detail.played)
        #expect(!detail.owned)
        #expect(detail.status == .finished)
    }

    @Test func unknownIDRollsBackWholeBatch() async throws {
        let store = try await TestDB.makeStore()
        let a = try await backlog(store, "A")
        let missing: Int64 = 999_999

        await #expect(throws: LibraryError.self) {
            try await store.markPlayed([a, missing], status: .finished)
        }
        // Rolled back — the valid id was NOT marked.
        let detail = try #require(try await store.gameDetail(id: a))
        #expect(!detail.played)
        #expect(detail.status == nil)
    }

    @Test func emptyIDsIsNoOp() async throws {
        let store = try await TestDB.makeStore()
        try await store.markPlayed([], status: .finished)   // must not throw
    }
}
