import Foundation
import Testing
import GRDB
@testable import VGN

/// The HLTB fill write path (PLAN §5.3): only-empty fields are filled, a prior
/// source is respected, `ttb_source = 'hltb'` only when a value was written and no
/// prior source existed, the HLTB id is persisted, and the change is Undo-able.
@Suite struct HLTBFillTests {

    private func store(seed: @Sendable @escaping (Database) throws -> Void = { _ in }) async throws -> (LibraryStore, Int64) {
        let db = try AppDatabase.inMemory()
        let gameID = try await db.dbWriter.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO games (title, played) VALUES ('Bloodborne', 1)")
            let id = db.lastInsertedRowID
            try seed(db)
            return id
        }
        return (LibraryStore(db), gameID)
    }

    private let full = HLTBCandidate(
        id: 2600, name: "Bloodborne", releaseYear: 2015,
        mainSeconds: 115200, mainExtraSeconds: 154800, completionistSeconds: 259200)

    @Test func fillsAllEmptyFieldsAndTagsHLTB() async throws {
        let (store, id) = try await store()
        let result = try await store.applyHLTBTimes(gameID: id, candidate: full)
        #expect(result.didWrite)
        #expect(result.setSource)
        #expect(result.setHLTBID)
        let detail = try await store.gameDetail(id: id)
        #expect(detail?.ttbHastilyS == 115200)
        #expect(detail?.ttbNormallyS == 154800)
        #expect(detail?.ttbCompletelyS == 259200)
        #expect(detail?.ttbSource == "hltb")
        #expect(detail?.hltbID == 2600)
    }

    @Test func neverOverwritesAnExistingValueOrIGDBSource() async throws {
        // IGDB already gave the main-story time; HLTB fills only the two gaps and the
        // source stays 'igdb'.
        let (store, id) = try await store { db in
            try db.execute(sql: """
                UPDATE games SET ttb_hastily_s = 99999, ttb_source = 'igdb' WHERE id = ?
                """, arguments: [db.lastInsertedRowID])
        }
        let result = try await store.applyHLTBTimes(gameID: id, candidate: full)
        #expect(!result.wroteHastily)                 // pre-existing value kept
        #expect(result.wroteNormally && result.wroteCompletely)
        #expect(!result.setSource)                    // prior 'igdb' respected
        let detail = try await store.gameDetail(id: id)
        #expect(detail?.ttbHastilyS == 99999)
        #expect(detail?.ttbSource == "igdb")
        #expect(detail?.hltbID == 2600)               // link still persisted
    }

    @Test func zeroOrMissingHLTBValuesAreNotWritten() async throws {
        let (store, id) = try await store()
        let empty = HLTBCandidate(id: 5, name: "X", mainSeconds: nil, mainExtraSeconds: 0, completionistSeconds: nil)
        let result = try await store.applyHLTBTimes(gameID: id, candidate: empty)
        #expect(!result.didWrite)
        #expect(!result.setSource)
        #expect(!result.setHLTBID)
        let detail = try await store.gameDetail(id: id)
        #expect(detail?.ttbSource == nil)
        #expect(detail?.hltbID == nil)
    }

    @Test func undoRestoresPreviousState() async throws {
        let (store, id) = try await store()
        let result = try await store.applyHLTBTimes(gameID: id, candidate: full)
        try await store.restoreTimeToBeat(gameID: id, result.previous)
        let detail = try await store.gameDetail(id: id)
        #expect(detail?.ttbNormallyS == nil)
        #expect(detail?.ttbSource == nil)
        #expect(detail?.hltbID == nil)
    }

    @Test func noEstimateScopeFindsOnlyFullyEmptyGames() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Empty', 1)")
            try db.execute(sql: "INSERT INTO games (id, title, played, ttb_normally_s) VALUES (2, 'Has Main', 1, 3600)")
            try db.execute(sql: "INSERT INTO games (id, title, played, ttb_hastily_s) VALUES (3, 'Has Rushed', 0, 1800)")
        }
        let store = LibraryStore(db)
        let ids = try await store.gameIDsWithNoTimeEstimate()
        #expect(ids == [1])
    }
}
