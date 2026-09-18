import Testing
@testable import VGN

/// Pure index-math tests for the Tier Board drag planner (PLAN §7): every drag
/// case — forward / backward within a row, across rows, into tails, onto the
/// letter block, multi-selection, no-op drops — driven with **no database** via
/// `TierBoardModel.planDrop`.
@Suite(.timeLimit(.minutes(1)))
struct RankingTierBoardModelTests {

    // A board: tier S (id 1) = [10,11,12,13], tier A (id 2) = [20,21] + unplaced 22.
    private func board() -> [TierBoardRow] {
        let s = TierInfo.defaults[0], a = TierInfo.defaults[1]
        func g(_ id: Int64, tier: TierInfo, key: RankKey?) -> GameSummary {
            GameSummary(id: id, title: "G\(id)", tierID: tier.id, tierLetter: tier.letter,
                        tierColorHex: tier.colorHex, rankKey: key, played: true, owned: true)
        }
        return [
            TierBoardRow(tier: s, placed: [g(10, tier: s, key: 1000), g(11, tier: s, key: 2000),
                                           g(12, tier: s, key: 3000), g(13, tier: s, key: 4000)]),
            TierBoardRow(tier: a, placed: [g(20, tier: a, key: 1000), g(21, tier: a, key: 2000)],
                         unplaced: [g(22, tier: a, key: nil)]),
            TierBoardRow(tier: TierInfo.defaults[2], placed: []),
            TierBoardRow(tier: TierInfo.defaults[3], placed: []),
            TierBoardRow(tier: TierInfo.defaults[4], placed: []),
            TierBoardRow(tier: TierInfo.defaults[5], placed: []),
        ]
    }

    private func placedIDs(_ board: [TierBoardRow], tier: Int64) -> [Int64] {
        board.first { $0.tier.id == tier }?.placed.map(\.id) ?? []
    }
    private func unplacedIDs(_ board: [TierBoardRow], tier: Int64) -> [Int64] {
        board.first { $0.tier.id == tier }?.unplaced.map(\.id) ?? []
    }

    // MARK: Within a row

    @Test func withinRowForward() {
        // Move 11 (index 1) to the gap between 12 and 13 (gap 3).
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 1, target: .gap(3))
        #expect(plan.moves == [RankMove(gameID: 11, toTier: 1, atIndex: 2)])
        #expect(placedIDs(plan.board, tier: 1) == [10, 12, 11, 13])
    }

    @Test func withinRowBackward() {
        // Move 12 (index 2) to the gap between 10 and 11 (gap 1).
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [12], toTier: 1, target: .gap(1))
        #expect(plan.moves == [RankMove(gameID: 12, toTier: 1, atIndex: 1)])
        #expect(placedIDs(plan.board, tier: 1) == [10, 12, 11, 13])
    }

    @Test func withinRowToFront() {
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [13], toTier: 1, target: .gap(0))
        #expect(plan.moves == [RankMove(gameID: 13, toTier: 1, atIndex: 0)])
        #expect(placedIDs(plan.board, tier: 1) == [13, 10, 11, 12])
    }

    @Test func droppingInOwnSlotIsNoOp() {
        // 11 is at index 1: gaps 1 (left of it) and 2 (right of it) are both no-ops.
        for gap in [1, 2] {
            let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 1, target: .gap(gap))
            #expect(plan.isNoOp, "gap \(gap) should be a no-op")
        }
    }

    // MARK: Across rows

    @Test func acrossRowsAtPosition() {
        // Move 11 from S into A at gap 1 (between 20 and 21).
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 2, target: .gap(1))
        #expect(plan.moves == [RankMove(gameID: 11, toTier: 2, atIndex: 1)])
        #expect(placedIDs(plan.board, tier: 2) == [20, 11, 21])
        #expect(placedIDs(plan.board, tier: 1) == [10, 12, 13])
    }

    @Test func acrossRowsClampsBeyondEnd() {
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [10], toTier: 2, target: .gap(99))
        #expect(plan.moves == [RankMove(gameID: 10, toTier: 2, atIndex: 2)])
        #expect(placedIDs(plan.board, tier: 2) == [20, 21, 10])
    }

    // MARK: Into tails / letter block

    @Test func dropIntoTailClearsPosition() {
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 2, target: .tail)
        #expect(plan.moves == [RankMove(gameID: 11, toTier: 2, atIndex: nil)])
        #expect(unplacedIDs(plan.board, tier: 2) == [22, 11])
        #expect(placedIDs(plan.board, tier: 1) == [10, 12, 13])
    }

    @Test func dropOntoOwnLetterBlockRequeues() {
        // 11 is placed in S; dropping onto the S letter block re-queues it.
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 1, target: .tail)
        #expect(plan.moves == [RankMove(gameID: 11, toTier: 1, atIndex: nil)])
        #expect(unplacedIDs(plan.board, tier: 1) == [11])
    }

    @Test func alreadyUnplacedTailDropIsNoOp() {
        // 22 already sits in A's unplaced tail.
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [22], toTier: 2, target: .tail)
        #expect(plan.isNoOp)
    }

    // MARK: Multi-selection (keeps relative order)

    @Test func multiSelectionForwardKeepsOrder() {
        // Select 11 and 13, drop into S at gap 1.
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [11, 13], toTier: 1, target: .gap(1))
        #expect(placedIDs(plan.board, tier: 1) == [10, 11, 13, 12])
        // The moves realise that order.
        #expect(plan.moves == [RankMove(gameID: 13, toTier: 1, atIndex: 2),
                               RankMove(gameID: 12, toTier: 1, atIndex: 3)])
    }

    @Test func multiSelectionAcrossRows() {
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [10, 12], toTier: 2, target: .gap(1))
        #expect(placedIDs(plan.board, tier: 2) == [20, 10, 12, 21])
        #expect(placedIDs(plan.board, tier: 1) == [11, 13])
    }

    @Test func multiSelectionIntoTail() {
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [10, 11], toTier: 2, target: .tail)
        #expect(plan.moves == [RankMove(gameID: 10, toTier: 2, atIndex: nil),
                               RankMove(gameID: 11, toTier: 2, atIndex: nil)])
        #expect(unplacedIDs(plan.board, tier: 2) == [22, 10, 11])
    }

    @Test func multiSelectionReordersToBoardOrder() {
        // Passed out of order — the planner sorts to board reading order (11 < 13).
        let plan = TierBoardModel.planDrop(board: board(), gameIDs: [13, 11], toTier: 2, target: .tail)
        #expect(plan.moves.map(\.gameID) == [11, 13])
    }

    // MARK: No-op / degenerate

    @Test func emptyDragIsNoOp() {
        #expect(TierBoardModel.planDrop(board: board(), gameIDs: [], toTier: 1, target: .gap(0)).isNoOp)
    }

    @Test func unknownTargetTierIsNoOp() {
        #expect(TierBoardModel.planDrop(board: board(), gameIDs: [11], toTier: 999, target: .tail).isNoOp)
    }
}
