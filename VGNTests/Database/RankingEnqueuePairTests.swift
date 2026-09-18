import Foundation
import Testing
import GRDB
@testable import VGN

/// "Duel exactly this pair" follow-up (PLAN §7): an enqueued pair is served before
/// natural refine candidates, persists across a new store instance, and is consumed
/// when answered.
@Suite struct RankingEnqueuePairTests {

    /// Four placed games in tier S, so natural adjacent refine pairs exist.
    private func makeFourPlaced() async throws -> (AppDatabase, RankingStore, [Int64]) {
        let (db, lib, rank) = try await RankTestDB.make()
        var ids: [Int64] = []
        for i in 0..<4 {
            let id = try await RankTestDB.addGame(lib, title: "G\(i)", tier: 1)
            try await RankTestDB.setKey(rank, id, RankKey((i + 1) * 1000))
            ids.append(id)
        }
        return (db, rank, ids)
    }

    @Test func enqueuedPairServedBeforeNaturalRefine() async throws {
        let (_, rank, ids) = try await makeFourPlaced()
        // The natural first refine pair is (g0, g1). Enqueue the non-adjacent (g0, g3).
        try await rank.enqueuePair(ids[0], ids[3])
        let prompt = try #require(try await rank.currentDuel())
        #expect(prompt.kind == .refine)
        #expect(prompt.candidate == ids[0])   // upper = higher-ranked of the pair
        #expect(prompt.opponent == ids[3])
    }

    @Test func enqueuedPairPersistsAcrossNewStore() async throws {
        let (db, rank, ids) = try await makeFourPlaced()
        try await rank.enqueuePair(ids[1], ids[2])
        // A brand-new store over the same database still serves the enqueued pair.
        let rank2 = RankingStore(db)
        let prompt = try #require(try await rank2.currentDuel())
        #expect(Set([prompt.candidate, prompt.opponent]) == Set([ids[1], ids[2]]))
    }

    @Test func answeringConsumesTheEnqueuedPair() async throws {
        let (_, rank, ids) = try await makeFourPlaced()
        try await rank.enqueuePair(ids[0], ids[3])
        let prompt = try #require(try await rank.currentDuel())
        _ = try await rank.answer(winner: prompt.candidate)
        // Next prompt is no longer the enqueued pair (it was consumed) — it falls
        // back to a natural adjacency.
        if let next = try await rank.currentDuel() {
            #expect(Set([next.candidate, next.opponent]) != Set([ids[0], ids[3]]))
        }
        // A comparison was logged (as refine).
        #expect(try await RankTestDB.comparisonCount(rank) == 1)
    }
}
