import Foundation
import Testing
@testable import VGN

/// Thousands of seeded, deterministic random operations against the engine, with
/// all invariants re-checked after every step. This is the point of doing the
/// ranking layer as pure logic: it can be fuzzed exhaustively without any UI/DB.
struct RandomOperationsTests {

    @Test("Random operation storm keeps every invariant", arguments: [
        UInt64(1), 2, 42, 1337, 0xDEADBEEF,
    ])
    func storm(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        let tierSorts: [TierID: Int] = [1: 0, 2: 1, 3: 2]
        var store = MockRankStore(tierSorts: tierSorts)
        var log: [Comparison] = []
        var nextID: GameID = 1
        var clock: Double = 0

        func randomTier() -> TierID { [1, 2, 3].randomElement(using: &rng)! }

        // Seed a handful of games so operations have something to chew on.
        for _ in 0..<8 {
            store.add(game: nextID, tier: randomTier(), key: nil)
            nextID += 1
        }

        let operations = 3000
        for step in 0..<operations {
            let snap = store.snapshot()
            let placedGames = snap.tiers.flatMap { $0.placed.map(\.id) }
            let unplacedGames = snap.tiers.flatMap { $0.unplaced }
            let allGames = placedGames + unplacedGames

            switch Int.random(in: 0..<9, using: &rng) {
            case 0 where allGames.count < 40:
                // Add a new unplaced game.
                store.add(game: nextID, tier: randomTier(), key: nil)
                nextID += 1

            case 1 where !unplacedGames.isEmpty:
                // Place an unplaced game via a duel session with random answers.
                let game = unplacedGames.randomElement(using: &rng)!
                let tier = snap.tiers.first { $0.unplaced.contains(game) }!
                var session = PlacementSession(placing: game, into: tier)
                while let opp = session.nextOpponent {
                    let _ = opp
                    session.answer(Bool.random(using: &rng) ? .candidateWins : .opponentWins)
                }
                store.apply(session.makeMutations() ?? [])

            case 2 where placedGames.count >= 2:
                // Reorder within a tier that has >= 2 placed games.
                let candidates = snap.tiers.filter { $0.placed.count >= 2 }
                if let slice = candidates.randomElement(using: &rng) {
                    let from = Int.random(in: 0..<slice.placed.count, using: &rng)
                    let to = Int.random(in: 0..<slice.placed.count, using: &rng)
                    store.apply(RankMoves.moveWithinTier(slice, from: from, to: to))
                }

            case 3 where !placedGames.isEmpty:
                // Move a placed game across tiers at a random index.
                let game = placedGames.randomElement(using: &rng)!
                let target = snap.orderedTiers.randomElement(using: &rng)!
                let idx = Int.random(in: 0...target.placed.count, using: &rng)
                store.apply(RankMoves.moveAcrossTiers(game, into: target, insertIndex: idx))

            case 4 where !placedGames.isEmpty:
                // Re-place (clear key, keep tier).
                let game = placedGames.randomElement(using: &rng)!
                store.apply(RankMoves.rePlace(game))

            case 5 where !allGames.isEmpty:
                // Set tier without a position (unplaced).
                let game = allGames.randomElement(using: &rng)!
                store.apply(RankMoves.setTierUnplaced(game, tier: randomTier()))

            case 6 where allGames.count > 4:
                // Un-play a game (drop it entirely).
                let game = allGames.randomElement(using: &rng)!
                store.apply(RankMoves.unplay(game))

            case 7:
                // Refine: resolve the top-priority pair with a random winner and log it.
                if let pair = RefineMode.next(snap, log: log) {
                    let winner = Bool.random(using: &rng) ? pair.upper : pair.lower
                    let loser = winner == pair.upper ? pair.lower : pair.upper
                    let ctx: Comparison.Context = {
                        if case .border = pair.context { return .border }
                        return .refine
                    }()
                    clock += 1
                    log.append(Comparison(winner: winner, loser: loser, date: clock, context: ctx))
                    if case .reorder(let muts) = RefineMode.resolve(pair, winner: winner, in: snap) {
                        store.apply(muts)
                    }
                }

            default:
                // Force a renumber pressure test: pack a tier then insert.
                if let slice = snap.tiers.first(where: { $0.placed.count >= 2 }) {
                    let from = slice.placed.count - 1
                    store.apply(RankMoves.moveWithinTier(slice, from: from, to: 0))
                }
            }

            // Invariants must hold after EVERY operation.
            let violations = Consistency.checkInvariants(store.snapshot())
            #expect(violations.isEmpty, "seed \(seed) step \(step): \(violations)")
        }

        // Final sanity: the global chart is a strict, contiguous 1…N numbering.
        let rows = GlobalRank.chart(store.snapshot())
        #expect(rows.map(\.position) == Array(1...max(1, rows.count)).prefix(rows.count).map { $0 })
    }

    @Test("Renumber pressure: force tiny gaps repeatedly and stay ordered")
    func renumberPressure() {
        var store = MockRankStore(tierSorts: [1: 0])
        // Two anchors with a minimal gap, then keep inserting between them.
        store.add(game: 1, tier: 1, key: 0)
        store.add(game: 2, tier: 1, key: 3)
        var nextID: GameID = 3
        for _ in 0..<50 {
            let slice = store.snapshot().slice(for: 1)!
            // Insert a fresh game at index 1 (between the first two) via a session.
            store.add(game: nextID, tier: 1, key: nil)
            var session = PlacementSession(placing: nextID, into: slice)
            // Drive to land at index 1 exactly: win vs index 0, lose vs the rest.
            while let opp = session.nextOpponent {
                let m = session.opponents.firstIndex { $0.id == opp }!
                session.answer(1 <= m ? .candidateWins : .opponentWins)
            }
            store.apply(session.makeMutations() ?? [])
            nextID += 1
            #expect(Consistency.checkInvariants(store.snapshot()).isEmpty)
        }
        // Everything is still strictly ordered and unique.
        let placed = store.snapshot().slice(for: 1)!.placed
        for i in 1..<placed.count { #expect(placed[i].key > placed[i - 1].key) }
        #expect(Set(placed.map(\.id)).count == placed.count)
    }
}
