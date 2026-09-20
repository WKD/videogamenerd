import Foundation
import Testing
import GRDB
@testable import VGN

/// Undo for Play Next "Start playing" (PLAN §7b) at the store level.
@Suite struct StartPlayingUndoTests {

    private func makeStores() async throws -> (AppDatabase, LibraryStore, RecommendationStore) {
        let db = try await TestDB.makeSeeded()
        return (db, LibraryStore(db), RecommendationStore(db))
    }

    private func gameState(_ db: AppDatabase, _ id: Int64) async throws -> (status: String?, played: Int, updatedAt: String?, pickedRows: Int) {
        try await db.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT status, played, updated_at FROM games WHERE id = ?", arguments: [id])!
            let picked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback WHERE game_id = ? AND action = 'picked'", arguments: [id]) ?? 0
            return (row["status"], row["played"], row["updated_at"], picked)
        }
    }

    @Test("Undo restores the exact prior state and removes the picked row")
    func restoresExactly() async throws {
        let (db, lib, rec) = try await makeStores()
        let id = try await lib.addGame(GameDraft(title: "Backlog", igdbID: 1,
                                                 platformIDs: ["ps4"], owned: true)).gameID
        let before = try await gameState(db, id)
        #expect(before.played == 0)
        #expect(before.status == nil)

        let token = try await rec.startPlayingCapturingUndo(gameID: id)
        let started = try await gameState(db, id)
        #expect(started.status == "playing")
        #expect(started.played == 1)
        #expect(started.pickedRows == 1)

        let outcome = try await rec.undoStartPlaying(token)
        #expect(outcome == .restored)
        let after = try await gameState(db, id)
        #expect(after.status == before.status)          // nil again
        #expect(after.played == before.played)          // 0 again
        #expect(after.updatedAt == before.updatedAt)    // verbatim
        #expect(after.pickedRows == 0)                  // the inserted row is gone
    }

    @Test("Undo does not disturb other feedback rows")
    func leavesOtherFeedback() async throws {
        let (db, lib, rec) = try await makeStores()
        let id = try await lib.addGame(GameDraft(title: "G", igdbID: 1,
                                                 platformIDs: ["ps4"], owned: true)).gameID
        try await rec.snooze(gameID: id)                 // a pre-existing feedback row
        let token = try await rec.startPlayingCapturingUndo(gameID: id)
        _ = try await rec.undoStartPlaying(token)
        let snoozeRows = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback WHERE game_id = ? AND action = 'snooze'", arguments: [id]) ?? 0
        }
        #expect(snoozeRows == 1)                         // untouched
    }

    @Test("Undo refuses when the game was ranked after starting (keeps the tier)")
    func refusesWhenRanked() async throws {
        let (db, lib, rec) = try await makeStores()
        let id = try await lib.addGame(GameDraft(title: "Backlog", igdbID: 1,
                                                 platformIDs: ["ps4"], owned: true)).gameID
        let token = try await rec.startPlayingCapturingUndo(gameID: id)
        // The user ranks it after starting (only possible because it is now played).
        _ = try await lib.setTier([id], tierID: 1)

        let outcome = try await rec.undoStartPlaying(token)
        #expect(outcome == .refusedRanked)
        let after = try await gameState(db, id)
        #expect(after.played == 1)                       // still played — tier intact
        let tier = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT tier_id FROM games WHERE id = ?", arguments: [id])
        }
        #expect(tier == 1)
        #expect(after.pickedRows == 1)                   // nothing removed on refusal
    }

    @Test("Undo refuses when restoring played = 0 would orphan the game")
    func refusesWouldOrphan() async throws {
        let (db, lib, rec) = try await makeStores()
        // A played, owned game (so it can exist), then strip ownership so it survives
        // only on `played = 1`. A hand-made token with previousPlayed = false models
        // the (constructed-away) case the guard defends against.
        let id = try await lib.addGame(GameDraft(title: "Owned then not", igdbID: 1,
                                                 platformIDs: ["ps4"], owned: true, played: true)).gameID
        try await db.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM product_games WHERE game_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM products WHERE id NOT IN (SELECT product_id FROM product_games)")
        }
        let token = StartPlayingUndo(gameID: id, previousStatus: nil, previousPlayed: false,
                                     previousRevisit: false, previousUpdatedAt: nil, pickedFeedbackID: 0)
        let outcome = try await rec.undoStartPlaying(token)
        #expect(outcome == .refusedWouldOrphan)
        let after = try await gameState(db, id)
        #expect(after.played == 1)                       // left intact
    }

    @Test("After undo the game is a candidate again, with its status reset")
    func candidateStatusReturns() async throws {
        let (_, lib, rec) = try await makeStores()
        // Enough ranked games so the engine runs (not pure crowd-prior corner cases).
        for i in 1...16 {
            _ = try await lib.addGame(GameDraft(title: "R\(i)", igdbID: Int64(i),
                                                platformIDs: ["ps4"], played: true, tierID: 3)).gameID
        }
        let cand = try await lib.addGame(GameDraft(title: "Cand", igdbID: 200,
                                                   platformIDs: ["ps4"], owned: true)).gameID
        try await lib.updateMetadata(gameID: cand, MetadataPatch(ttbNormallyS: 10 * 3600))

        func candidate(_ r: PlayNextResult) -> PlayNextSuggestion? {
            let all = [r.hero].compactMap { $0 } + r.shortlist + r.alternatives + r.unknownLength
            return all.first { $0.id == cand }
        }

        let token = try await rec.startPlayingCapturingUndo(gameID: cand)
        // A playing game is still a candidate, but now carries the playing status.
        #expect(candidate(try await rec.recommend(bracket: TimeBracket(shelf: .weekend)))?.status == .playing)

        _ = try await rec.undoStartPlaying(token)
        let restored = candidate(try await rec.recommend(bracket: TimeBracket(shelf: .weekend)))
        #expect(restored != nil)                 // still a candidate
        #expect(restored?.status == nil)         // back to unplayed, as it was
    }
}
