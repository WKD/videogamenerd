import Foundation
import Testing
import GRDB
@testable import VGN

/// Copy removal is undoable (owner request 2026-09-20): un-owning / removing a copy restores
/// the product row(s), their `product_games`, and any game deleted as an orphan — reusing the
/// reconcile snapshot machinery. Store-level coverage of the actual restore.
@Suite struct CopyRemovalUndoTests {

    private func copyID(_ store: LibraryStore, game gameID: Int64, platform: String) async throws -> Int64 {
        let detail = try #require(try await store.gameDetail(id: gameID))
        return try #require(detail.copies.first { $0.platformID == platform }).productID
    }

    private func platforms(_ store: LibraryStore, _ id: Int64) async throws -> [String] {
        try #require(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).first { $0.id == id }).platformIDs
    }

    /// Removing one copy of a two-copy game is undoable — the product + its membership come back.
    @Test func undoRestoresARemovedCopy() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Celeste", platformIDs: ["mac"], owned: true, format: .digital)).gameID
        _ = try await store.addCopy(gameID: id, platformID: "pc", format: .digital)
        let macPID = try await copyID(store, game: id, platform: "mac")

        let (outcome, undo) = try await store.removeProductsCapturingUndo([macPID])
        #expect(outcome == .ok)
        let undoRec = try #require(undo)
        #expect(undoRec.actionName == "Remove Copy")
        #expect(try await platforms(store, id) == ["pc"])

        try await store.restoreReconcile(undoRec)
        #expect(Set(try await platforms(store, id)) == ["mac", "pc"])
        // The restored product carries its columns (a single digital copy on mac is back).
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.copies.contains { $0.platformID == "mac" && $0.format == .digital })
    }

    /// Removing the last copy of an owned-not-played game orphan-deletes it; undo brings the
    /// game AND its copy back.
    @Test func undoRestoresAnOrphanDeletedGame() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(
            title: "Solo", platformIDs: ["ps4"], owned: true, format: .physical)).gameID
        let pid = try await copyID(store, game: id, platform: "ps4")

        // Without confirmation → no change, no undo.
        let (blocked, none) = try await store.removeProductsCapturingUndo([pid])
        #expect(blocked == .wouldOrphan([id]))
        #expect(none == nil)

        // Confirmed → the game is deleted, with an undo that restores it.
        let (outcome, undo) = try await store.removeProductsCapturingUndo([pid], confirmOrphanDelete: true)
        #expect(outcome == .ok)
        #expect(try await store.gamesOnce(filter: LibraryFilter(scope: .all)).contains { $0.id == id } == false)

        try await store.restoreReconcile(try #require(undo))
        let back = try #require(try await store.gameDetail(id: id))
        #expect(back.title == "Solo")
        #expect(back.copies.map(\.platformID) == ["ps4"])
    }

    /// Removing a compilation member is undoable (store level).
    @Test func undoRestoresACompilationMember() async throws {
        let store = try await TestDB.makeStore()
        let (pid, _) = try await store.addCompilation(
            product: ProductDraft(title: "Trilogy", platformID: "ps3", format: .physical),
            members: [CompilationMemberDraft(title: "One", igdbID: 1, position: 0),
                      CompilationMemberDraft(title: "Two", igdbID: 2, position: 1)])
        let members = try await store.compilationMembers(productID: pid).map(\.gameID)

        // Mark one member played so removing it does not orphan (keeps the game to observe).
        try await store.markPlayed([members[0]], status: nil)
        let (outcome, undo) = try await store.removeCompilationMemberCapturingUndo(
            productID: pid, gameID: members[0])
        #expect(outcome == .ok)
        #expect(try await store.compilationMembers(productID: pid).map(\.gameID) == [members[1]])

        try await store.restoreReconcile(try #require(undo))
        #expect(Set(try await store.compilationMembers(productID: pid).map(\.gameID)) == Set(members))
    }
}
