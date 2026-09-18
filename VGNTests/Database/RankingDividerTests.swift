import Foundation
import Testing
@testable import VGN

/// Movable-divider + derived-score store tests over an in-memory database
/// (PLAN §7 extension): store result matches the pure move, one-step undo restores
/// the prior order exactly, invariants hold, and `derivedScore(for:)` works.
/// `@MainActor`, serialized, hard-timeout (EXECUTION test hygiene).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RankingDividerTests {

    /// Seed tier S = [s0,s1,s2] and A = [a0,a1] placed in order; return their ids.
    private func seed() async throws -> (rank: RankingStore, sID: Int64, aID: Int64,
                                         sIDs: [Int64], aIDs: [Int64]) {
        let (_, lib, rank) = try await RankTestDB.make()
        let tiers = try await lib.tiers()
        let sID = tiers[0].id, aID = tiers[1].id
        var sIDs: [Int64] = [], aIDs: [Int64] = []
        for i in 0..<3 {
            sIDs.append(try await lib.addGame(
                GameDraft(title: "S\(i)", platformIDs: ["pc"], owned: true, played: true, tierID: sID)).gameID)
        }
        for i in 0..<2 {
            aIDs.append(try await lib.addGame(
                GameDraft(title: "A\(i)", platformIDs: ["pc"], owned: true, played: true, tierID: aID)).gameID)
        }
        for (i, id) in sIDs.enumerated() { try await rank.move(gameID: id, toTier: sID, atIndex: i) }
        for (i, id) in aIDs.enumerated() { try await rank.move(gameID: id, toTier: aID, atIndex: i) }
        return (rank, sID, aID, sIDs, aIDs)
    }

    private func order(_ rank: RankingStore, _ tier: Int64) async throws -> [Int64] {
        let snap = try await RankTestDB.snapshot(rank)
        return snap.slice(for: tier)?.placed.map(\.id) ?? []
    }

    @Test func downwardMoveMatchesPureAndKeepsInvariants() async throws {
        let s = try await seed()
        let outcome = try await s.rank.moveDivider(between: s.sID, and: s.aID, by: 1)
        #expect(outcome.movedIDs == [s.aIDs[0]])
        #expect(try await order(s.rank, s.sID) == s.sIDs + [s.aIDs[0]])
        #expect(try await order(s.rank, s.aID) == [s.aIDs[1]])
        #expect(outcome.upperPlaced == 4)
        #expect(outcome.lowerPlaced == 1)
        #expect(try await s.rank.verifyInvariants().isEmpty)
    }

    @Test func upwardMoveMatchesPure() async throws {
        let s = try await seed()
        let outcome = try await s.rank.moveDivider(between: s.sID, and: s.aID, by: -1)
        #expect(outcome.movedIDs == [s.sIDs[2]])
        #expect(try await order(s.rank, s.sID) == [s.sIDs[0], s.sIDs[1]])
        #expect(try await order(s.rank, s.aID) == [s.sIDs[2]] + s.aIDs)
        #expect(try await s.rank.verifyInvariants().isEmpty)
    }

    @Test func undoRestoresExactOrder() async throws {
        let s = try await seed()
        let beforeS = try await order(s.rank, s.sID)
        let beforeA = try await order(s.rank, s.aID)

        _ = try await s.rank.moveDivider(between: s.sID, and: s.aID, by: 2)
        #expect(try await order(s.rank, s.sID) == s.sIDs + [s.aIDs[0], s.aIDs[1]])

        let undone = try await s.rank.undo()
        #expect(undone)
        #expect(try await order(s.rank, s.sID) == beforeS)
        #expect(try await order(s.rank, s.aID) == beforeA)
        #expect(try await s.rank.verifyInvariants().isEmpty)
    }

    @Test func zeroMoveIsNoOp() async throws {
        let s = try await seed()
        let outcome = try await s.rank.moveDivider(between: s.sID, and: s.aID, by: 0)
        #expect(outcome.movedIDs.isEmpty)
        #expect(try await order(s.rank, s.sID) == s.sIDs)
    }

    @Test func derivedScoreForTopGameIsBandTop() async throws {
        let s = try await seed()
        let top = await s.rank.derivedScore(for: s.sIDs[0])
        #expect(top?.value == 10.0)
        let all = try await s.rank.allDerivedScores()
        #expect(all[s.sIDs[0]]?.value == 10.0)
        #expect(all.count == 5)
    }
}
