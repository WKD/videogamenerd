import Testing
@testable import VGN

/// Pure `TierDividerMove` tests (PLAN §7 extension): downward / upward moves for
/// every k including clamping and empty tiers, and that only placed games cross
/// while unplaced tails stay put.
@Suite(.timeLimit(.minutes(1)))
struct TierDividerMoveTests {

    // Upper tier S (id 1) = [1,2,3] + unplaced [90]; lower tier A (id 2) = [4,5,6] + unplaced [91].
    private func snapshot() -> RankSnapshot {
        RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0,
                      placed: [RankedItem(id: 1, key: 1000), RankedItem(id: 2, key: 2000), RankedItem(id: 3, key: 3000)],
                      unplaced: [90]),
            TierSlice(tier: 2, sort: 1,
                      placed: [RankedItem(id: 4, key: 1000), RankedItem(id: 5, key: 2000), RankedItem(id: 6, key: 3000)],
                      unplaced: [91]),
        ])
    }

    /// The id order of the `renumber` for `tier` in a mutation batch, if any.
    private func renumberIDs(_ mutations: [RankMutation], tier: Int64) -> [Int64]? {
        for m in mutations {
            if case let .renumber(t, items) = m, t == tier { return items.map(\.id) }
        }
        return nil
    }

    private func retieredTo(_ mutations: [RankMutation], tier: Int64) -> [Int64] {
        mutations.compactMap {
            if case let .setTier(id, t, _) = $0, t == tier { return id }
            return nil
        }
    }

    // MARK: Downward (k > 0)

    @Test func downwardMovesTopOfLowerToBottomOfUpper() {
        let snap = snapshot()
        let moved = TierDividerMove.movedIDs(snapshot: snap, upperTier: 1, lowerTier: 2, by: 2)
        #expect(moved == [4, 5])
        let muts = TierDividerMove.mutations(snapshot: snap, upperTier: 1, lowerTier: 2, by: 2)
        #expect(retieredTo(muts, tier: 1) == [4, 5])
        #expect(renumberIDs(muts, tier: 1) == [1, 2, 3, 4, 5])   // appended at the bottom
        #expect(renumberIDs(muts, tier: 2) == [6])               // remainder keeps order
    }

    // MARK: Upward (k < 0)

    @Test func upwardMovesBottomOfUpperToTopOfLower() {
        let snap = snapshot()
        let moved = TierDividerMove.movedIDs(snapshot: snap, upperTier: 1, lowerTier: 2, by: -1)
        #expect(moved == [3])
        let muts = TierDividerMove.mutations(snapshot: snap, upperTier: 1, lowerTier: 2, by: -1)
        #expect(retieredTo(muts, tier: 2) == [3])
        #expect(renumberIDs(muts, tier: 1) == [1, 2])
        #expect(renumberIDs(muts, tier: 2) == [3, 4, 5, 6])      // prepended at the top
    }

    // MARK: Clamping and no-ops

    @Test func downwardClampsToLowerCount() {
        let snap = snapshot()
        #expect(TierDividerMove.movedIDs(snapshot: snap, upperTier: 1, lowerTier: 2, by: 99) == [4, 5, 6])
        let muts = TierDividerMove.mutations(snapshot: snap, upperTier: 1, lowerTier: 2, by: 99)
        #expect(renumberIDs(muts, tier: 1) == [1, 2, 3, 4, 5, 6])
        #expect(renumberIDs(muts, tier: 2) == nil)   // lower now empty → no renumber
    }

    @Test func upwardClampsToUpperCount() {
        let snap = snapshot()
        #expect(TierDividerMove.movedIDs(snapshot: snap, upperTier: 1, lowerTier: 2, by: -99) == [1, 2, 3])
    }

    @Test func zeroIsNoOp() {
        #expect(TierDividerMove.mutations(snapshot: snapshot(), upperTier: 1, lowerTier: 2, by: 0).isEmpty)
    }

    @Test func downwardFromEmptyLowerIsNoOp() {
        let snap = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 1000)]),
            TierSlice(tier: 2, sort: 1, placed: []),
        ])
        #expect(TierDividerMove.mutations(snapshot: snap, upperTier: 1, lowerTier: 2, by: 3).isEmpty)
    }

    @Test func unplacedTailsNeverMove() {
        let muts = TierDividerMove.mutations(snapshot: snapshot(), upperTier: 1, lowerTier: 2, by: 2)
        // No mutation touches the unplaced tail ids 90 / 91.
        let touched = RankingStore.touchedIDs(muts)
        #expect(!touched.contains(90))
        #expect(!touched.contains(91))
    }
}
