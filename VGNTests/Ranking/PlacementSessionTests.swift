import Foundation
import Testing
@testable import VGN

struct PlacementSessionTests {

    /// Build a tier slice with `n` placed opponents (ids 1…n) at well-spaced keys.
    private func slice(n: Int, tier: TierID = 1, sort: Int = 0) -> TierSlice {
        let placed = (1...max(1, n)).prefix(n).map { RankedItem(id: GameID($0), key: RankKey($0) * 1000) }
        return TierSlice(tier: tier, sort: sort, placed: Array(placed))
    }

    @Test("Empty tier needs zero duels")
    func emptyTier() {
        let s = TierSlice(tier: 1, sort: 0, placed: [])
        let session = PlacementSession(placing: 100, into: s)
        #expect(session.isComplete)
        #expect(session.nextOpponent == nil)
        #expect(session.comparisonsMade == 0)
        let muts = session.makeMutations()
        #expect(muts == [.setKey(id: 100, key: RankKeySpace.initial)])
    }

    @Test("Oracle lands at exactly the true position within the comparison budget")
    func oracleExhaustive() {
        let candidate: GameID = 10_000
        for n in 0...16 {
            let tierSlice = slice(n: n)
            let budget = PlacementSession.ceilLog2(n + 1)
            for p in 0...n {
                var session = PlacementSession(placing: candidate, into: tierSlice)
                driveOracle(&session, truePosition: p)
                #expect(session.isComplete, "n=\(n) p=\(p) did not complete")
                #expect(session.insertionIndex == p, "n=\(n) p=\(p) landed at \(session.insertionIndex)")
                #expect(session.comparisonsMade <= budget,
                        "n=\(n) p=\(p) used \(session.comparisonsMade) > budget \(budget)")

                // Apply the resulting mutations and confirm the final ordering
                // really has the candidate at position p.
                var store = MockRankStore(tierSorts: [1: 0])
                for item in tierSlice.placed { store.add(game: item.id, tier: 1, key: item.key) }
                store.add(game: candidate, tier: 1, key: nil) // unplaced before placing
                store.apply(session.makeMutations() ?? [])
                let order = store.snapshot().slice(for: 1)!.placed.map(\.id)
                var expected = tierSlice.placed.map(\.id)
                expected.insert(candidate, at: p)
                #expect(order == expected, "n=\(n) p=\(p) order \(order) != \(expected)")
            }
        }
    }

    @Test("Undo at every step restores the exact prior state")
    func undoRestores() {
        let candidate: GameID = 999
        for n in 1...16 {
            let tierSlice = slice(n: n)
            for p in 0...n {
                var session = PlacementSession(placing: candidate, into: tierSlice)
                while let opponent = session.nextOpponent {
                    let before = session   // value semantics: exact prior state
                    let m = session.opponents.firstIndex(where: { $0.id == opponent })!
                    session.answer(p <= m ? .candidateWins : .opponentWins)
                    let didUndo = session.undo()
                    #expect(didUndo)
                    #expect(before == session, "undo mismatch n=\(n) p=\(p)")
                    // Re-apply to make progress.
                    session.answer(p <= m ? .candidateWins : .opponentWins)
                }
                #expect(session.insertionIndex == p)
            }
        }
    }

    @Test("Undo past the beginning is a no-op")
    func undoUnderflow() {
        var session = PlacementSession(placing: 1, into: slice(n: 3))
        #expect(session.undo() == false)
    }

    @Test("Codable round-trip mid-session preserves behaviour")
    func codableMidSession() {
        let candidate: GameID = 42
        let tierSlice = slice(n: 15)
        for p in 0...15 {
            var session = PlacementSession(placing: candidate, into: tierSlice)
            // Answer roughly half the duels, then serialise/deserialise.
            var steps = 0
            let half = session.estimatedTotal / 2
            while let opponent = session.nextOpponent, steps < half {
                let m = session.opponents.firstIndex(where: { $0.id == opponent })!
                session.answer(p <= m ? .candidateWins : .opponentWins)
                steps += 1
            }
            let data = try! JSONEncoder().encode(session)
            var revived = try! JSONDecoder().decode(PlacementSession.self, from: data)
            #expect(revived == session)
            driveOracle(&revived, truePosition: p)
            #expect(revived.insertionIndex == p)
        }
    }

    @Test("Resume after an opponent is deleted still completes sensibly")
    func resumeOpponentDeleted() {
        let candidate: GameID = 500
        let tierSlice = slice(n: 10)
        // Place at true position 5, but stop early.
        var session = PlacementSession(placing: candidate, into: tierSlice)
        _ = session.nextOpponent
        let firstMid = session.opponents.firstIndex(where: { $0.id == session.nextOpponent! })!
        session.answer(5 <= firstMid ? .candidateWins : .opponentWins)

        // Now delete two opponents from the tier and reorder nothing else.
        var placed = tierSlice.placed
        placed.removeAll { $0.id == 3 || $0.id == 8 }
        let changed = TierSlice(tier: 1, sort: 0, placed: placed)
        var resumed = session.revalidated(against: changed)
        // Drive to completion using the NEW opponent order and a fresh oracle
        // (position doesn't matter — we only assert it never crashes and places).
        while let opp = resumed.nextOpponent {
            let m = resumed.opponents.firstIndex(where: { $0.id == opp })!
            resumed.answer(m >= resumed.opponents.count / 2 ? .candidateWins : .opponentWins)
        }
        #expect(resumed.isComplete)
        #expect(resumed.insertionIndex >= 0 && resumed.insertionIndex <= resumed.opponents.count)
        let muts = resumed.makeMutations()
        #expect(muts != nil)
    }

    @Test("Resume against a reordered tier never crashes and always places")
    func resumeReordered() {
        var rng = SeededRNG(seed: 0xF00D)
        let candidate: GameID = 777
        for trial in 0..<200 {
            let n = Int.random(in: 1...12, using: &rng)
            let tierSlice = slice(n: n)
            let p = Int.random(in: 0...n, using: &rng)
            var session = PlacementSession(placing: candidate, into: tierSlice)
            // Answer a random prefix of the duels.
            let stop = Int.random(in: 0...session.estimatedTotal, using: &rng)
            var steps = 0
            while let opp = session.nextOpponent, steps < stop {
                let m = session.opponents.firstIndex(where: { $0.id == opp })!
                session.answer(p <= m ? .candidateWins : .opponentWins)
                steps += 1
            }
            // Shuffle + maybe drop opponents.
            var placed = tierSlice.placed.shuffled(using: &rng)
            if Bool.random(using: &rng), !placed.isEmpty { placed.removeFirst() }
            // Re-key so they are strictly increasing in the new order.
            let reslice = TierSlice(tier: 1, sort: 0,
                placed: placed.enumerated().map { RankedItem(id: $0.element.id, key: RankKey($0.offset + 1) * 1000) })
            var resumed = session.revalidated(against: reslice)
            while let opp = resumed.nextOpponent {
                let m = resumed.opponents.firstIndex(where: { $0.id == opp })!
                resumed.answer(Bool.random(using: &rng) ? .candidateWins : .opponentWins)
                _ = m
            }
            #expect(resumed.isComplete, "trial \(trial) did not complete")
            #expect(resumed.makeMutations() != nil)
        }
    }

    @Test("Skip produces no mutation and no opponent")
    func skip() {
        var session = PlacementSession(placing: 1, into: slice(n: 5))
        session.skip()
        #expect(session.nextOpponent == nil)
        #expect(session.makeMutations() == nil)
    }

    @Test("Progress readout is monotonic and within budget")
    func progress() {
        var session = PlacementSession(placing: 1, into: slice(n: 12))
        let total = session.estimatedTotal
        var last = 0
        while let opp = session.nextOpponent {
            #expect(session.comparisonsMade >= last)
            last = session.comparisonsMade
            let m = session.opponents.firstIndex(where: { $0.id == opp })!
            session.answer(m >= 6 ? .candidateWins : .opponentWins)
        }
        #expect(session.comparisonsMade <= total)
    }
}
