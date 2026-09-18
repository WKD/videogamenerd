import Foundation
import Testing
import GRDB
@testable import VGN

/// Batch-move follow-up (PLAN §7): a multi-select Tier Board drop is one
/// transaction / one undo step, and produces the same board as the equivalent
/// sequence of single moves.
@Suite struct RankingBatchMoveTests {

    private func historyDepth(_ rank: RankingStore) async throws -> Int {
        try await rank.dbReader.read { db in
            try RankingStore.loadDuelState(db).history.count
        }
    }

    @Test func batchEqualsNSinglesAndIsOneUndoStep() async throws {
        // Build tier S (1) with three placed games, tier A (2) empty.
        let (_, lib, rankBatch) = try await RankTestDB.make()
        let g1 = try await RankTestDB.addGame(lib, title: "G1", tier: 1)
        let g2 = try await RankTestDB.addGame(lib, title: "G2", tier: 1)
        let g3 = try await RankTestDB.addGame(lib, title: "G3", tier: 1)
        try await RankTestDB.setKey(rankBatch, g1, 1000)
        try await RankTestDB.setKey(rankBatch, g2, 2000)
        try await RankTestDB.setKey(rankBatch, g3, 3000)

        // The batch: move g1 and g3 into A (2) as a block at index 0, then 1.
        let moves: [(gameID: Int64, toTier: Int64, atIndex: Int?)] = [
            (g1, 2, 0), (g3, 2, 1),
        ]
        try await rankBatch.move(moves)
        let batchSnap = try await RankTestDB.snapshot(rankBatch)
        #expect(RankTestDB.placedOrder(batchSnap, tier: 2) == [g1, g3])
        #expect(RankTestDB.placedOrder(batchSnap, tier: 1) == [g2])
        // One undo step.
        #expect(try await historyDepth(rankBatch) == 1)

        // The same moves applied one at a time on a fresh identical DB.
        let (_, lib2, rankSingle) = try await RankTestDB.make()
        let s1 = try await RankTestDB.addGame(lib2, title: "G1", tier: 1)
        let s2 = try await RankTestDB.addGame(lib2, title: "G2", tier: 1)
        let s3 = try await RankTestDB.addGame(lib2, title: "G3", tier: 1)
        try await RankTestDB.setKey(rankSingle, s1, 1000)
        try await RankTestDB.setKey(rankSingle, s2, 2000)
        try await RankTestDB.setKey(rankSingle, s3, 3000)
        try await rankSingle.move(gameID: s1, toTier: 2, atIndex: 0)
        try await rankSingle.move(gameID: s3, toTier: 2, atIndex: 1)
        let singleSnap = try await RankTestDB.snapshot(rankSingle)

        // Equivalent final board (ids line up because both DBs seed in the same order).
        #expect(RankTestDB.placedOrder(singleSnap, tier: 2) == [s1, s3])
        #expect(RankTestDB.placedOrder(singleSnap, tier: 1) == [s2])
        // N single moves → N undo steps.
        #expect(try await historyDepth(rankSingle) == 2)
    }

    @Test func undoReversesWholeBatch() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g1 = try await RankTestDB.addGame(lib, title: "G1", tier: 1)
        let g2 = try await RankTestDB.addGame(lib, title: "G2", tier: 1)
        try await RankTestDB.setKey(rank, g1, 1000)
        try await RankTestDB.setKey(rank, g2, 2000)

        try await rank.move([(g1, 2, 0), (g2, 2, 1)])
        #expect(RankTestDB.placedOrder(try await RankTestDB.snapshot(rank), tier: 2) == [g1, g2])

        // A single undo restores both games to S in their original order.
        #expect(try await rank.undo())
        let restored = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.placedOrder(restored, tier: 1) == [g1, g2])
        #expect(RankTestDB.placedOrder(restored, tier: 2).isEmpty)
    }
}
