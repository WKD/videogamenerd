import Foundation
import Testing
import GRDB
@testable import VGN

/// `setHLTBLink` (PLAN §5.3, D5 — "Link Only" / "Unlink") stores or clears the id without
/// touching times, and returns the previous id so a one-step Undo can be applied directly
/// (headless-safe, since `UndoManager.undo()` hangs). `@MainActor` + GRDB ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct HLTBLinkStoreTests {

    private func store(hastily: Int?, id: Int64?) async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_hastily_s, ttb_source, hltb_id)
                VALUES (1, 'Bloodborne', 1, ?, 'igdb', ?)
                """, arguments: [hastily, id])
        }
        return LibraryStore(db)
    }

    @Test(.timeLimit(.minutes(1)))
    func linkOnlyStoresIDWithoutTouchingTimes() async throws {
        let store = try await store(hastily: 3600, id: nil)
        let previous = try await store.setHLTBLink(gameID: 1, hltbID: 42)
        #expect(previous == nil)
        let d = try await store.gameDetail(id: 1)
        #expect(d?.hltbID == 42)
        #expect(d?.ttbHastilyS == 3600)     // untouched
        #expect(d?.ttbSource == "igdb")     // untouched
    }

    @Test(.timeLimit(.minutes(1)))
    func unlinkClearsIDAndTimesStay() async throws {
        let store = try await store(hastily: 3600, id: 42)
        let previous = try await store.setHLTBLink(gameID: 1, hltbID: nil)
        #expect(previous == 42)
        let d = try await store.gameDetail(id: 1)
        #expect(d?.hltbID == nil)
        #expect(d?.ttbHastilyS == 3600)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoInverseRestoresThePreviousLink() async throws {
        let store = try await store(hastily: 3600, id: 7)
        // Link Only to 42, capturing the previous id (7).
        let previous = try await store.setHLTBLink(gameID: 1, hltbID: 42)
        #expect(previous == 7)
        #expect(try await store.gameDetail(id: 1)?.hltbID == 42)
        // Apply the Undo inverse directly (UndoManager.undo() hangs headless).
        _ = try await store.setHLTBLink(gameID: 1, hltbID: previous)
        #expect(try await store.gameDetail(id: 1)?.hltbID == 7)
    }
}
