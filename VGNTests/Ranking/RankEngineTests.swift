import Foundation
import Testing
@testable import VGN

// MARK: - Moves

struct RankMovesTests {

    private func slice(_ ids: [GameID], tier: TierID = 1, sort: Int = 0, spacing: RankKey = 1000) -> TierSlice {
        let placed = ids.enumerated().map { RankedItem(id: $0.element, key: RankKey($0.offset + 1) * spacing) }
        return TierSlice(tier: tier, sort: sort, placed: placed)
    }

    @Test("Reorder within a tier moves a game to the target index")
    func moveWithin() {
        let s = slice([1, 2, 3, 4, 5])
        var store = MockRankStore(tierSorts: [1: 0])
        for item in s.placed { store.add(game: item.id, tier: 1, key: item.key) }
        // Move id 5 (index 4) to index 0 (top).
        store.apply(RankMoves.moveWithinTier(store.snapshot().slice(for: 1)!, from: 4, to: 0))
        #expect(store.snapshot().slice(for: 1)!.placed.map(\.id) == [5, 1, 2, 3, 4])
        // Move id 1 (now index 1) to the end.
        let cur = store.snapshot().slice(for: 1)!
        let from = cur.placed.firstIndex { $0.id == 1 }!
        store.apply(RankMoves.moveWithinTier(cur, from: from, to: 4))
        #expect(store.snapshot().slice(for: 1)!.placed.map(\.id) == [5, 2, 3, 4, 1])
    }

    @Test("Reorder into a packed neighbourhood renumbers and preserves order")
    func moveWithinRenumber() {
        // Adjacent keys with no gaps anywhere.
        let placed = [RankedItem(id: 1, key: 10), RankedItem(id: 2, key: 11), RankedItem(id: 3, key: 12)]
        let s = TierSlice(tier: 1, sort: 0, placed: placed)
        // Move id 1 into the middle (index 1) — between adjacent keys 11 and 12,
        // where no integer fits → renumber. Result order [2,1,3].
        let muts = RankMoves.moveWithinTier(s, from: 0, to: 1)
        guard case .renumber(_, let items) = muts.first else { Issue.record("expected renumber"); return }
        #expect(items.map(\.id) == [2, 1, 3])
        for i in 1..<items.count { #expect(items[i].key > items[i - 1].key) }
    }

    @Test("Move across tiers sets tier and a valid in-range key")
    func moveAcross() {
        var store = MockRankStore(tierSorts: [1: 0, 2: 1])
        for item in slice([1, 2, 3], tier: 1).placed { store.add(game: item.id, tier: 1, key: item.key) }
        for item in slice([4, 5], tier: 2).placed { store.add(game: item.id, tier: 2, key: item.key) }
        // Move id 2 into tier 2 between 4 and 5 (index 1).
        let target = store.snapshot().slice(for: 2)!
        store.apply(RankMoves.moveAcrossTiers(2, into: target, insertIndex: 1))
        #expect(store.tier(of: 2) == 2)
        #expect(store.snapshot().slice(for: 2)!.placed.map(\.id) == [4, 2, 5])
        #expect(store.snapshot().slice(for: 1)!.placed.map(\.id) == [1, 3])
    }

    @Test("Set-tier-unplaced clears the key; re-place queues; unplay drops everything")
    func tierOps() {
        var store = MockRankStore(tierSorts: [1: 0, 2: 1])
        store.add(game: 1, tier: 1, key: 1000)
        // Set unplaced in tier 2.
        store.apply(RankMoves.setTierUnplaced(1, tier: 2))
        #expect(store.tier(of: 1) == 2)
        #expect(store.key(of: 1) == nil)
        #expect(store.snapshot().slice(for: 2)!.unplaced == [1])
        // Give it a key, then re-place (clear key, keep tier).
        store.apply([.setKey(id: 1, key: 5000)])
        store.apply(RankMoves.rePlace(1))
        #expect(store.tier(of: 1) == 2)
        #expect(store.key(of: 1) == nil)
        // Unplay → no tier at all.
        store.apply(RankMoves.unplay(1))
        #expect(store.hasTier(1) == false)
    }
}

// MARK: - Queue

struct RankQueueTests {

    @Test("Unplaced games come first, ordered by tier sort then queue order")
    func unplacedFirst() {
        var store = MockRankStore(tierSorts: [1: 0, 2: 1])
        store.add(game: 10, tier: 1, key: 1000)   // placed
        store.add(game: 20, tier: 2, key: nil)     // unplaced (added first among unplaced)
        store.add(game: 21, tier: 1, key: nil)     // unplaced, higher tier
        let snap = store.snapshot()
        let placements = RankQueue.placements(snap)
        // tier 1 (sort 0) unplaced before tier 2 (sort 1).
        #expect(placements.first?.game == 21)
        #expect(RankQueue.unplacedCount(snap) == 2)
        if case .place(let g, let t)? = RankQueue.next(snap, log: []) {
            #expect(g == 21 && t == 1)
        } else { Issue.record("expected place") }
    }

    @Test("With nothing unplaced, the queue offers refine pairs")
    func refineWhenPlaced() {
        var store = MockRankStore(tierSorts: [1: 0])
        store.add(game: 1, tier: 1, key: 1000)
        store.add(game: 2, tier: 1, key: 2000)
        let snap = store.snapshot()
        #expect(RankQueue.unplacedCount(snap) == 0)
        if case .refine(let pair)? = RankQueue.next(snap, log: []) {
            #expect(pair.upper == 1 && pair.lower == 2)
        } else { Issue.record("expected refine") }
    }
}

// MARK: - Refine

struct RefineModeTests {

    private func twoTierSnapshot() -> RankSnapshot {
        let s = TierSlice(tier: 1, sort: 0, placed: [
            RankedItem(id: 1, key: 1000), RankedItem(id: 2, key: 2000), RankedItem(id: 3, key: 3000),
        ])
        let a = TierSlice(tier: 2, sort: 1, placed: [
            RankedItem(id: 4, key: 1000), RankedItem(id: 5, key: 2000),
        ])
        return RankSnapshot(tiers: [s, a])
    }

    @Test("Never-compared pairs are prioritised over compared ones")
    func priorityNeverCompared() {
        let snap = twoTierSnapshot()
        // Log: pair (1,2) compared recently, (2,3) long ago.
        let log = [
            Comparison(winner: 1, loser: 2, date: 1000, context: .refine),
            Comparison(winner: 2, loser: 3, date: 10, context: .refine),
        ]
        let pairs = RefineMode.pairs(snap, log: log)
        // Border pair (3,4) is never compared → should be near the front,
        // before the two compared within-tier pairs.
        let idx34 = pairs.firstIndex { $0.upper == 3 && $0.lower == 4 }!
        let idx12 = pairs.firstIndex { $0.upper == 1 && $0.lower == 2 }!
        let idx23 = pairs.firstIndex { $0.upper == 2 && $0.lower == 3 }!
        #expect(idx34 < idx12)
        #expect(idx34 < idx23)
        // Among compared, older (2,3) before newer (1,2).
        #expect(idx23 < idx12)
    }

    @Test("Within-tier upset swaps the two games")
    func withinUpset() {
        let snap = twoTierSnapshot()
        let pair = RefinePair(upper: 1, lower: 2, context: .withinTier(1))
        // Lower (2) wins → swap.
        let out = RefineMode.resolve(pair, winner: 2, in: snap)
        var store = MockRankStore(tierSorts: [1: 0, 2: 1])
        for slice in snap.tiers { for it in slice.placed { store.add(game: it.id, tier: slice.tier, key: it.key) } }
        guard case .reorder(let muts) = out else { Issue.record("expected reorder"); return }
        store.apply(muts)
        #expect(store.snapshot().slice(for: 1)!.placed.map(\.id) == [2, 1, 3])
        // Upper wins → no change.
        #expect(RefineMode.resolve(pair, winner: 1, in: snap) == .noChange)
    }

    @Test("Border upset yields a promote suggestion, not a mutation")
    func borderSuggestion() {
        let snap = twoTierSnapshot()
        // Bottom of tier 1 is id 3; top of tier 2 is id 4.
        let pair = RefinePair(upper: 3, lower: 4, context: .border(upper: 1, lower: 2))
        let out = RefineMode.resolve(pair, winner: 4, in: snap)
        #expect(out == .suggestion(BorderSuggestion(game: 4, fromTier: 2, toTier: 1, kind: .promote)))
        // Higher-tier game wins → confirmed, no change.
        #expect(RefineMode.resolve(pair, winner: 3, in: snap) == .noChange)
    }
}

// MARK: - Consistency

struct ConsistencyTests {

    @Test("Invariants pass for a well-formed snapshot")
    func invariantsOK() {
        let snap = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 100), RankedItem(id: 2, key: 200)], unplaced: [3]),
        ])
        #expect(Consistency.checkInvariants(snap).isEmpty)
    }

    @Test("Invariants catch disordered keys, duplicate keys and duplicate games")
    func invariantsFail() {
        let disordered = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 300), RankedItem(id: 2, key: 200)]),
        ])
        #expect(Consistency.checkInvariants(disordered).contains { $0.kind == .nonIncreasingKeys })

        let dupKey = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 200), RankedItem(id: 2, key: 200)]),
        ])
        #expect(Consistency.checkInvariants(dupKey).contains { $0.kind == .duplicateKey })

        let dupGame = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 100)], unplaced: [1]),
        ])
        #expect(Consistency.checkInvariants(dupGame).contains { $0.kind == .duplicateGame })
    }

    @Test("Acyclic comparison log has no disputes")
    func noCycle() {
        let log = [
            Comparison(winner: 1, loser: 2, date: 1, context: .refine),
            Comparison(winner: 2, loser: 3, date: 2, context: .refine),
            Comparison(winner: 1, loser: 3, date: 3, context: .refine),
        ]
        #expect(Consistency.detectContradictions(log).isEmpty)
    }

    @Test("A three-cycle A>B>C>A is reported as a dispute")
    func threeCycle() {
        let log = [
            Comparison(winner: 1, loser: 2, date: 1, context: .refine),
            Comparison(winner: 2, loser: 3, date: 2, context: .refine),
            Comparison(winner: 3, loser: 1, date: 3, context: .refine),
        ]
        let disputes = Consistency.detectContradictions(log)
        #expect(disputes.count == 1)
        #expect(disputes[0].games == [1, 2, 3])
        #expect(disputes[0].cycle.first == 1)          // canonicalised to smallest
        #expect(Set(disputes[0].cycle) == [1, 2, 3])
    }

    @Test("Superseded comparisons are ignored (latest wins)")
    func supersededIgnored() {
        // First 1>2, later 2>1. With 2>3 and 3>1 there would be a cycle only if
        // the OLD 1>2 edge counted; latest 2>1 breaks it.
        let log = [
            Comparison(winner: 1, loser: 2, date: 1, context: .refine),
            Comparison(winner: 2, loser: 3, date: 2, context: .refine),
            Comparison(winner: 3, loser: 1, date: 3, context: .refine),
            Comparison(winner: 2, loser: 1, date: 4, context: .refine), // supersedes 1>2
        ]
        // Now edges: 2>3, 3>1, 2>1 → acyclic.
        #expect(Consistency.detectContradictions(log).isEmpty)
    }

    @Test("Two independent cycles are both reported, deterministically")
    func twoCycles() {
        let log = [
            Comparison(winner: 1, loser: 2, date: 1, context: .refine),
            Comparison(winner: 2, loser: 1, date: 1, context: .refine),   // wait: same pair
        ]
        // The above is one pair compared twice; not a cycle. Build real disjoint cycles:
        let log2 = [
            Comparison(winner: 1, loser: 2, date: 1, context: .refine),
            Comparison(winner: 2, loser: 3, date: 1, context: .refine),
            Comparison(winner: 3, loser: 1, date: 1, context: .refine),
            Comparison(winner: 10, loser: 11, date: 1, context: .refine),
            Comparison(winner: 11, loser: 12, date: 1, context: .refine),
            Comparison(winner: 12, loser: 10, date: 1, context: .refine),
        ]
        _ = log
        let disputes = Consistency.detectContradictions(log2)
        #expect(disputes.count == 2)
        #expect(disputes[0].games == [1, 2, 3])
        #expect(disputes[1].games == [10, 11, 12])
    }
}

// MARK: - Global rank

struct GlobalRankTests {

    private func snapshot() -> RankSnapshot {
        RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 1, key: 100), RankedItem(id: 2, key: 200)], unplaced: [99]),
            TierSlice(tier: 2, sort: 1, placed: [RankedItem(id: 3, key: 100), RankedItem(id: 4, key: 200)]),
        ])
    }

    @Test("Global chart numbers placed games 1…N across tiers, excluding unplaced")
    func chart() {
        let rows = GlobalRank.chart(snapshot())
        #expect(rows.map(\.id) == [1, 2, 3, 4])
        #expect(rows.map(\.position) == [1, 2, 3, 4])
        #expect(rows.allSatisfy { $0.id != 99 })
    }

    @Test("Filtered chart reports derived and global positions")
    func filtered() {
        // Subset = games 2 and 4.
        let rows = GlobalRank.filteredChart(snapshot(), subset: [2, 4])
        #expect(rows.count == 2)
        #expect(rows[0].id == 2 && rows[0].derivedPosition == 1 && rows[0].globalPosition == 2)
        #expect(rows[1].id == 4 && rows[1].derivedPosition == 2 && rows[1].globalPosition == 4)
    }
}
