import Foundation
import Testing
import GRDB
@testable import VGN

/// The SQL applier must reproduce `MockRankStore` (the reference applier) exactly,
/// and the tier/move operations must keep the v1 invariants.
@Suite struct RankingStoreApplierTests {

    // MARK: - Applier equivalence storm

    /// Drive the same seeded random operation stream through BOTH `MockRankStore`
    /// and `RankingStore` (identical mutation batches), and assert identical
    /// resulting placed orders + matching unplaced sets + SQL invariants after
    /// every step. Game ids stay aligned because rows are never deleted here.
    @Test("Random operation storm: SQL applier == MockRankStore",
          arguments: [UInt64(1), 42, 1337])
    func applierEquivalence(seed: UInt64) async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        var rng = SeededRNG(seed: seed)
        let tierSorts: [TierID: Int] = [1: 0, 2: 1, 3: 2]
        var mock = MockRankStore(tierSorts: tierSorts)
        var log: [Comparison] = []
        var nextID: GameID = 1
        var clock: Double = 0

        func randomTier() -> TierID { [1, 2, 3].randomElement(using: &rng)! }

        func addGame(tier: TierID) async throws {
            let id = try await lib.addGame(GameDraft(title: "G\(nextID)", tierID: tier)).gameID
            #expect(id == nextID, "seed \(seed): game ids drifted (\(id) != \(nextID))")
            mock.add(game: id, tier: tier, key: nil)
            nextID += 1
        }

        func applyBoth(_ mutations: [RankMutation]) async throws {
            mock.apply(mutations)
            try await rank.dbWriter.write { db in try RankingStore.applyMutations(mutations, db) }
        }

        for _ in 0..<8 { try await addGame(tier: randomTier()) }

        for step in 0..<220 {
            let snap = mock.snapshot()
            let placedGames = snap.tiers.flatMap { $0.placed.map(\.id) }
            let unplacedGames = snap.tiers.flatMap { $0.unplaced }
            let allGames = placedGames + unplacedGames

            switch Int.random(in: 0..<9, using: &rng) {
            case 0 where allGames.count < 28:
                try await addGame(tier: randomTier())

            case 1 where !unplacedGames.isEmpty:
                let game = unplacedGames.randomElement(using: &rng)!
                let tier = snap.tiers.first { $0.unplaced.contains(game) }!
                var session = PlacementSession(placing: game, into: tier)
                while session.nextOpponent != nil {
                    session.answer(Bool.random(using: &rng) ? .candidateWins : .opponentWins)
                }
                try await applyBoth(session.makeMutations() ?? [])

            case 2 where placedGames.count >= 2:
                if let slice = snap.tiers.filter({ $0.placed.count >= 2 }).randomElement(using: &rng) {
                    let from = Int.random(in: 0..<slice.placed.count, using: &rng)
                    let to = Int.random(in: 0..<slice.placed.count, using: &rng)
                    try await applyBoth(RankMoves.moveWithinTier(slice, from: from, to: to))
                }

            case 3 where !placedGames.isEmpty:
                let game = placedGames.randomElement(using: &rng)!
                let target = snap.orderedTiers.randomElement(using: &rng)!
                let idx = Int.random(in: 0...target.placed.count, using: &rng)
                try await applyBoth(RankMoves.moveAcrossTiers(game, into: target, insertIndex: idx))

            case 4 where !placedGames.isEmpty:
                try await applyBoth(RankMoves.rePlace(placedGames.randomElement(using: &rng)!))

            case 5 where !allGames.isEmpty:
                try await applyBoth(RankMoves.setTierUnplaced(allGames.randomElement(using: &rng)!, tier: randomTier()))

            case 6 where allGames.count > 4:
                try await applyBoth(RankMoves.unplay(allGames.randomElement(using: &rng)!))

            case 7:
                if let pair = RefineMode.next(snap, log: log) {
                    let winner = Bool.random(using: &rng) ? pair.upper : pair.lower
                    let loser = winner == pair.upper ? pair.lower : pair.upper
                    let ctx: Comparison.Context = { if case .border = pair.context { return .border }; return .refine }()
                    clock += 1
                    log.append(Comparison(winner: winner, loser: loser, date: clock, context: ctx))
                    if case let .reorder(muts) = RefineMode.resolve(pair, winner: winner, in: snap) {
                        try await applyBoth(muts)
                    }
                }

            default:
                if let slice = snap.tiers.first(where: { $0.placed.count >= 2 }) {
                    try await applyBoth(RankMoves.moveWithinTier(slice, from: slice.placed.count - 1, to: 0))
                }
            }

            let sql = try await RankTestDB.snapshot(rank)
            #expect(GlobalRank.chart(mock.snapshot()).map(\.id) == GlobalRank.chart(sql).map(\.id),
                    "seed \(seed) step \(step): placed order diverged")
            for tier in [TierID(1), 2, 3] {
                let m = Set(mock.snapshot().slice(for: tier)?.unplaced ?? [])
                let s = Set(sql.slice(for: tier)?.unplaced ?? [])
                #expect(m == s, "seed \(seed) step \(step): unplaced set diverged in tier \(tier)")
            }
            #expect(Consistency.checkInvariants(sql).isEmpty, "seed \(seed) step \(step): SQL invariants")
        }
    }

    // MARK: - Individual mutation semantics

    @Test func setTierNilDropsTierAndKey() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        try await RankTestDB.setKey(rank, g, 1000)
        try await rank.dbWriter.write { db in
            try RankingStore.applyMutations([.setTier(id: g, tier: nil, key: nil)], db)
        }
        let snap = try await RankTestDB.snapshot(rank)
        #expect(snap.slice(for: 1)?.placed.isEmpty == true)
        #expect(snap.slice(for: 1)?.unplaced.isEmpty == true)
    }

    @Test func clearKeyKeepsTierMakesUnplaced() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "A", tier: 2)
        try await RankTestDB.setKey(rank, g, 1000)
        try await rank.dbWriter.write { db in try RankingStore.applyMutations([.clearKey(id: g)], db) }
        let snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.unplaced(snap, tier: 2) == [g])
        #expect(RankTestDB.placedOrder(snap, tier: 2).isEmpty)
    }

    // MARK: - Renumber path (hundreds of same-spot inserts)

    @Test func renumberKeepsStrictOrderUnderTinyGaps() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a0 = try await RankTestDB.addGame(lib, title: "A0", tier: 1)
        let a1 = try await RankTestDB.addGame(lib, title: "A1", tier: 1)
        try await RankTestDB.setKey(rank, a0, 0)
        try await RankTestDB.setKey(rank, a1, 3)   // minimal gap

        for i in 0..<300 {
            let g = try await RankTestDB.addGame(lib, title: "N\(i)", tier: 1)
            let snap = try await RankTestDB.snapshot(rank)
            let slice = snap.slice(for: 1)!
            var session = PlacementSession(placing: g, into: slice)
            // Land at index 1 (between the current first two): win vs index 0, lose vs rest.
            while let opp = session.nextOpponent {
                let m = session.opponents.firstIndex { $0.id == opp }!
                session.answer(1 <= m ? .candidateWins : .opponentWins)
            }
            let mutations = session.makeMutations() ?? []
            try await rank.dbWriter.write { db in try RankingStore.applyMutations(mutations, db) }
            let after = try await RankTestDB.snapshot(rank)
            #expect(Consistency.checkInvariants(after).isEmpty, "step \(i)")
        }
        let final = try await RankTestDB.snapshot(rank)
        let placed = final.slice(for: 1)!.placed
        #expect(placed.count == 302)
        for i in 1..<placed.count { #expect(placed[i].key > placed[i - 1].key) }
        #expect(Set(placed.map(\.id)).count == placed.count)
        // The two original anchors stay at the ends (nothing landed below a1 or above a0).
        #expect(placed.first?.id == a0)
        #expect(placed.last?.id == a1)
    }

    // MARK: - Moves

    @Test func moveWithinAcrossAndIntoUnplacedTail() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        var ids: [Int64] = []
        for i in 0..<4 { ids.append(try await RankTestDB.addGame(lib, title: "A\(i)", tier: 1)) }
        for (i, id) in ids.enumerated() { try await RankTestDB.setKey(rank, id, RankKey((i + 1) * 1_000_000)) }
        // [A0,A1,A2,A3]

        // Within tier: A2 to the top.
        try await rank.move(gameID: ids[2], toTier: 1, atIndex: 0)
        #expect(RankTestDB.placedOrder(try await RankTestDB.snapshot(rank), tier: 1)
                == [ids[2], ids[0], ids[1], ids[3]])

        // Across tiers: A0 to top of tier 2.
        try await rank.move(gameID: ids[0], toTier: 2, atIndex: 0)
        var snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.placedOrder(snap, tier: 2) == [ids[0]])
        #expect(!RankTestDB.placedOrder(snap, tier: 1).contains(ids[0]))

        // Into the unplaced tail: A1 dropped as unplaced in tier 1.
        try await rank.move(gameID: ids[1], toTier: 1, atIndex: nil)
        snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.unplaced(snap, tier: 1) == [ids[1]])
        #expect(!RankTestDB.placedOrder(snap, tier: 1).contains(ids[1]))
        #expect(Consistency.checkInvariants(snap).isEmpty)
    }

    // MARK: - Tier operations

    @Test func setTierSameTierIsNoOpKeepsKey() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        try await RankTestDB.setKey(rank, g, 4242)
        // Re-setting the tier it already has must NOT drop the fine-rank key.
        let outcome = try await rank.setTier([g], tierID: 1)
        #expect(outcome.applied == [g])
        let detail = try #require(try await lib.gameDetail(id: g))
        #expect(detail.rankKey == 4242)
    }

    @Test func setTierChangeClearsKeyAndSkipsUnplayed() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let played = try await RankTestDB.addGame(lib, title: "P", tier: 1)
        try await RankTestDB.setKey(rank, played, 999)
        let unplayed = try await lib.addGame(GameDraft(title: "U", platformIDs: ["pc"], owned: true)).gameID

        let outcome = try await rank.setTier([played, unplayed], tierID: 2)
        #expect(outcome.applied == [played])
        #expect(outcome.skippedUnplayed == [unplayed])
        let detail = try #require(try await lib.gameDetail(id: played))
        #expect(detail.tierID == 2)
        #expect(detail.rankKey == nil)   // real change → unplaced
    }

    @Test func libraryStoreSetTierDelegatesSameBehaviour() async throws {
        // LibraryStore.setTier now shares RankingStore's implementation.
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        try await RankTestDB.setKey(rank, g, 555)
        _ = try await lib.setTier([g], tierID: 1)   // same tier via LibraryStore
        #expect(try await lib.gameDetail(id: g)?.rankKey == 555)  // key preserved
    }

    @Test func clearAndRePlace() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let g = try await RankTestDB.addGame(lib, title: "A", tier: 3)
        try await RankTestDB.setKey(rank, g, 777)

        try await rank.rePlace(g)
        var snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.unplaced(snap, tier: 3) == [g])   // key dropped, tier kept

        try await rank.clearTier(g)
        snap = try await RankTestDB.snapshot(rank)
        #expect(snap.slice(for: 3)?.placed.isEmpty == true)
        #expect(snap.slice(for: 3)?.unplaced.isEmpty == true)
        #expect(try await lib.gameDetail(id: g)?.tierID == nil)
    }

    @Test func verifyInvariantsHealthyStore() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        let b = try await RankTestDB.addGame(lib, title: "B", tier: 1)
        try await RankTestDB.setKey(rank, a, 100)
        try await RankTestDB.setKey(rank, b, 200)
        #expect(try await rank.verifyInvariants().isEmpty)
    }
}
