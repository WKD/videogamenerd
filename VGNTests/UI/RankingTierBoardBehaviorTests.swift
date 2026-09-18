import Foundation
import Testing
@testable import VGN

/// Tier Board model behaviour: keyboard re-tier / clear / nudge against a fake
/// backend, optimistic apply + reconciliation, and an end-to-end pass over an
/// in-memory database asserting the resulting `tierBoardOnce()` order and empty
/// `verifyInvariants()` (PLAN §7). `@MainActor`, serialized, hard-timeout per
/// EXECUTION test hygiene.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct RankingTierBoardBehaviorTests {

    // A deterministic fake board: S=[10,11,12], A=[20], rest empty.
    private func fake() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.autoApplyMoves = true
        let s = TierInfo.defaults[0], a = TierInfo.defaults[1]
        func g(_ id: Int64, _ tier: TierInfo, _ key: RankKey?) -> GameSummary {
            GameSummary(id: id, title: "G\(id)", tierID: tier.id, tierLetter: tier.letter,
                        tierColorHex: tier.colorHex, rankKey: key, played: true, owned: true)
        }
        b.board = [
            TierBoardRow(tier: s, placed: [g(10, s, 1000), g(11, s, 2000), g(12, s, 3000)]),
            TierBoardRow(tier: a, placed: [g(20, a, 1000)]),
            TierBoardRow(tier: TierInfo.defaults[2]),
            TierBoardRow(tier: TierInfo.defaults[3]),
            TierBoardRow(tier: TierInfo.defaults[4]),
            TierBoardRow(tier: TierInfo.defaults[5]),
        ]
        return b
    }

    private func placed(_ board: [TierBoardRow], _ tier: Int64) -> [Int64] {
        board.first { $0.tier.id == tier }?.placed.map(\.id) ?? []
    }
    private func unplaced(_ board: [TierBoardRow], _ tier: Int64) -> [Int64] {
        board.first { $0.tier.id == tier }?.unplaced.map(\.id) ?? []
    }

    // MARK: Optimistic apply + reconciliation

    @Test func dropReconcilesToObservedTruth() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        #expect(placed(m.rows, 1) == [10, 11, 12])

        await m.drop([10], toTier: 1, target: .gap(3))   // 10 → end of S
        #expect(placed(m.rows, 1) == [11, 12, 10])
        #expect(b.moves.count == 1)
        #expect(m.selection == [10])
    }

    // MARK: Keyboard — re-tier (S…F → new tier's tail)

    @Test func retierSelectionMovesToTierTail() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(11)
        await m.retierSelection(letter: "A")
        #expect(unplaced(m.rows, 2).contains(11))
        #expect(placed(m.rows, 1) == [10, 12])
    }

    @Test func retierIntoSameUnplacedTierIsNoOp() async {
        let b = fake()
        // Put 12 already in A's unplaced tail.
        b.board = ScriptedRankingBackend.applyMove(b.board, gameID: 12, toTier: 2, atIndex: nil)
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(12)
        await m.retierSelection(letter: "A")
        #expect(b.moves.isEmpty)   // already unplaced in A → nothing issued
    }

    // MARK: Keyboard — clear (0)

    @Test func clearSelectionTierRemovesFromBoard() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(10)
        m.select(11, additive: true)
        await m.clearSelectionTier()
        #expect(b.clearedTiers == [10, 11])
        #expect(placed(m.rows, 1) == [12])
        #expect(m.selection.isEmpty)
    }

    // MARK: Keyboard — nudge within tier (⌥←/⌥→)

    @Test func nudgeForwardMovesOneSlot() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(11)                    // index 1 of [10,11,12]
        await m.nudgeWithinTier(forward: true)
        #expect(placed(m.rows, 1) == [10, 12, 11])
    }

    @Test func nudgeBackwardMovesOneSlot() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(12)                    // index 2
        await m.nudgeWithinTier(forward: false)
        #expect(placed(m.rows, 1) == [10, 12, 11])
    }

    @Test func nudgeForwardAtEndDoesNothing() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(12)                    // last
        await m.nudgeWithinTier(forward: true)
        #expect(b.moves.isEmpty)
    }

    // MARK: Keyboard — nudge across tiers (⌥↑/⌥↓)

    @Test func nudgeDownMovesToNextTierTail() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(11)
        await m.nudgeAcrossTier(up: false)      // S → A tail
        #expect(unplaced(m.rows, 2).contains(11))
    }

    @Test func nudgeUpAtTopDoesNothing() async {
        let b = fake()
        let m = TierBoardModel(backend: b)
        await m.start()
        m.select(11)
        await m.nudgeAcrossTier(up: true)       // S is already the top tier
        #expect(b.moves.isEmpty)
    }

    // MARK: End-to-end over an in-memory database

    @Test func endToEndDragReordersStoreAndKeepsInvariants() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let rank = RankingStore(db)
        let backend = LiveRankingBackend(ranking: rank, library: lib, coverLoader: NoopCoverLoader())
        let tiers = try await lib.tiers()
        let sID = tiers[0].id, aID = tiers[1].id

        // Five played games, tiered into S and placed in a known order g0…g4.
        var ids: [Int64] = []
        for i in 0..<5 {
            let id = try await lib.addGame(
                GameDraft(title: "Game \(i)", platformIDs: ["pc"], owned: true, played: true, tierID: sID)).gameID
            ids.append(id)
        }
        for (i, id) in ids.enumerated() { try await rank.move(gameID: id, toTier: sID, atIndex: i) }

        let m = TierBoardModel(backend: backend)
        await m.start()
        defer { m.stop() }
        #expect(m.rows.first { $0.tier.id == sID }?.placed.map(\.id) == ids)

        // Drag g0 to the end of S.
        await m.drop([ids[0]], toTier: sID, target: .gap(5))
        var board = try await backend.tierBoardOnce()
        #expect(board.first { $0.tier.id == sID }?.placed.map(\.id)
                == [ids[1], ids[2], ids[3], ids[4], ids[0]])
        #expect(try await rank.verifyInvariants().isEmpty)

        // Drag g1 and g2 across into A at the front.
        await m.drop([ids[1], ids[2]], toTier: aID, target: .gap(0))
        board = try await backend.tierBoardOnce()
        #expect(board.first { $0.tier.id == aID }?.placed.map(\.id) == [ids[1], ids[2]])
        #expect(board.first { $0.tier.id == sID }?.placed.map(\.id) == [ids[3], ids[4], ids[0]])
        #expect(try await rank.verifyInvariants().isEmpty)

        // Drag g3 into A's unplaced tail.
        await m.drop([ids[3]], toTier: aID, target: .tail)
        board = try await backend.tierBoardOnce()
        #expect(board.first { $0.tier.id == aID }?.unplaced.map(\.id) == [ids[3]])
        #expect(try await rank.verifyInvariants().isEmpty)
    }
}
