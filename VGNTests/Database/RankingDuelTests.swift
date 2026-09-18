import Foundation
import Testing
import GRDB
@testable import VGN

/// The resumable placement / refine / border duel flow, driven through the public
/// `RankingStore` duel API exactly as the Duel view will.
@Suite struct RankingDuelTests {

    /// A tier of `count` placed anchors in a known order (A0 best … A[count-1]).
    private func buildTier(_ lib: LibraryStore, _ rank: RankingStore,
                           tier: Int64, count: Int, owned: Bool = false) async throws -> [Int64] {
        var anchors: [Int64] = []
        for i in 0..<count {
            let id = try await RankTestDB.addGame(lib, title: "A\(tier)_\(i)", tier: tier, owned: owned)
            anchors.append(id)
            try await RankTestDB.setKey(rank, id, RankKey(i + 1) * (1 << 30))
        }
        return anchors
    }

    /// Drive the placement of `target` with a perfect oracle: it should land at
    /// `truePosition` among `anchors`. Returns the number of answers given.
    @discardableResult
    private func drivePlacement(_ rank: RankingStore, target: Int64, anchors: [Int64],
                                truePosition p: Int) async throws -> Int {
        var answers = 0
        while let prompt = try await rank.currentDuel(),
              prompt.kind == .placement, prompt.candidate == target {
            let m = anchors.firstIndex(of: prompt.opponent)!
            _ = try await rank.answer(winner: p <= m ? target : prompt.opponent)
            answers += 1
        }
        return answers
    }

    // MARK: - Full placement flow, n = 0…12

    @Test func placementLandsAtOracleWithinLogComparisons() async throws {
        for n in 0...12 {
            for p in Set([0, n / 2, n]) {
                let (_, lib, rank) = try await RankTestDB.make()
                let anchors = try await buildTier(lib, rank, tier: 1, count: n)
                let target = try await RankTestDB.addGame(lib, title: "TARGET", tier: 1)

                let answers = try await drivePlacement(rank, target: target, anchors: anchors, truePosition: p)
                let bound = PlacementSession.ceilLog2(n + 1)
                #expect(answers <= bound, "n=\(n) p=\(p): \(answers) answers > bound \(bound)")
                #expect(try await RankTestDB.comparisonCount(rank) == answers,
                        "n=\(n) p=\(p): logged comparisons != answers")

                let snap = try await RankTestDB.snapshot(rank)
                let placed = RankTestDB.placedOrder(snap, tier: 1)
                #expect(placed.count == n + 1, "n=\(n) p=\(p): not fully placed")
                #expect(placed.firstIndex(of: target) == p, "n=\(n) p=\(p): landed at \(String(describing: placed.firstIndex(of: target)))")
                // Anchors keep their relative order.
                let anchorOrder = placed.filter { $0 != target }
                #expect(anchorOrder == anchors, "n=\(n) p=\(p): anchors reordered")
                #expect(Consistency.checkInvariants(snap).isEmpty)
            }
        }
    }

    // MARK: - Kill and resume

    @Test func killAndResumeMidSession() async throws {
        let (db, lib, rank) = try await RankTestDB.make()
        let anchors = try await buildTier(lib, rank, tier: 1, count: 6)
        let target = try await RankTestDB.addGame(lib, title: "TARGET", tier: 1)

        // Answer one duel, then "relaunch" with a brand-new store over the same DB.
        let prompt = try #require(try await rank.currentDuel())
        #expect(prompt.candidate == target)
        _ = try await rank.answer(winner: target)   // target wins vs the mid opponent

        let resumed = RankingStore(db)
        let cont = try #require(try await resumed.currentDuel())
        #expect(cont.kind == .placement)
        #expect(cont.candidate == target)
        #expect(cont.comparisonsMade == 1)   // resumed mid-session, not restarted

        // Finish placing at position 0 and confirm it landed.
        _ = try await drivePlacement(resumed, target: target, anchors: anchors, truePosition: 0)
        let snap = try await RankTestDB.snapshot(resumed)
        #expect(RankTestDB.placedOrder(snap, tier: 1).first == target)
        #expect(Consistency.checkInvariants(snap).isEmpty)
    }

    // MARK: - Resume after the opponent changed underneath the session

    enum OpponentChange: CaseIterable { case deleted, unplayed, retiered }

    @Test(arguments: OpponentChange.allCases)
    func resumeAfterOpponentChanged(_ change: OpponentChange) async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let anchors = try await buildTier(lib, rank, tier: 1, count: 5, owned: true)
        let target = try await RankTestDB.addGame(lib, title: "TARGET", tier: 1)

        // Begin the placement (one answer, so a session with an opponent fact exists).
        _ = try #require(try await rank.currentDuel())
        _ = try await rank.answer(winner: target)

        // Mutate one anchor (not the target) underneath the persisted session.
        let victim = anchors[0]
        switch change {
        case .deleted:  try await lib.deleteGame(victim)
        case .unplayed: _ = try await lib.setPlayed([victim], false)          // owned → kept, tier cleared
        case .retiered: _ = try await rank.setTier([victim], tierID: 2)       // moved to tier 2
        }

        // The session must recover: keep dueling the target without crashing.
        var guardCount = 0
        while let prompt = try await rank.currentDuel(), prompt.kind == .placement, prompt.candidate == target {
            _ = try await rank.answer(winner: prompt.opponent)   // arbitrary, consistent answers
            guardCount += 1
            #expect(guardCount < 20, "placement did not converge after \(change)")
        }
        let snap = try await RankTestDB.snapshot(rank)
        #expect(snap.slice(for: 1)?.placed.map(\.id).contains(target) == true, "target not placed after \(change)")
        #expect(Consistency.checkInvariants(snap).isEmpty, "invariants after \(change)")
    }

    // MARK: - Undo (per-answer through completion)

    @Test func undoStepsBackEveryAnswerAndReversesCompletion() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let anchors = try await buildTier(lib, rank, tier: 1, count: 7)
        let target = try await RankTestDB.addGame(lib, title: "TARGET", tier: 1)

        let answers = try await drivePlacement(rank, target: target, anchors: anchors, truePosition: 3)
        #expect(answers >= 2)
        #expect(try await RankTestDB.snapshot(rank).slice(for: 1)!.placed.map(\.id).contains(target))

        // Undo every answer; the comparison count must drop by one each time.
        for remaining in stride(from: answers - 1, through: 0, by: -1) {
            #expect(try await rank.undo() == true)
            #expect(try await RankTestDB.comparisonCount(rank) == remaining)
        }
        // Target is unplaced again; the session is back at zero answers.
        let snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.unplaced(snap, tier: 1).contains(target))
        #expect(!RankTestDB.placedOrder(snap, tier: 1).contains(target))
        let prompt = try #require(try await rank.currentDuel())
        #expect(prompt.candidate == target)
        #expect(prompt.comparisonsMade == 0)
        // Nothing left to undo.
        #expect(try await rank.undo() == false)
    }

    // MARK: - Skip defers the current placement

    @Test func skipDefersToNextGame() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        _ = try await buildTier(lib, rank, tier: 1, count: 1)      // one placed opponent
        let u1 = try await RankTestDB.addGame(lib, title: "U1", tier: 1)
        let u2 = try await RankTestDB.addGame(lib, title: "U2", tier: 1)

        let first = try #require(try await rank.currentDuel())
        #expect(first.candidate == u1)   // queue head
        try await rank.skip()
        let second = try #require(try await rank.currentDuel())
        #expect(second.candidate == u2)  // u1 deferred to the back
        _ = u2
    }

    // MARK: - Refine ordering + swap

    @Test func refineNeverComparedFirstThenSwapOnLoss() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a = try await buildTier(lib, rank, tier: 1, count: 3)   // A0,A1,A2 placed, none unplaced

        // No placements remain → the first refine pair is the never-compared
        // top adjacency (A0,A1).
        let first = try #require(try await rank.currentDuel())
        #expect(first.kind == .refine)
        #expect(first.candidate == a[0])
        #expect(first.opponent == a[1])

        // The lower game wins → swap.
        let outcome = try await rank.answer(winner: a[1])
        #expect(outcome == .refined(swapped: true))
        var snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.placedOrder(snap, tier: 1) == [a[1], a[0], a[2]])
        #expect(try await RankTestDB.comparisonCount(rank) == 1)

        // Next: the still-never-compared pair (A0,A2); upper wins → no change.
        let second = try #require(try await rank.currentDuel())
        #expect(second.kind == .refine)
        #expect(second.candidate == a[0] && second.opponent == a[2])
        let confirm = try await rank.answer(winner: a[0])
        #expect(confirm == .refined(swapped: false))
        snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.placedOrder(snap, tier: 1) == [a[1], a[0], a[2]])
        #expect(try await RankTestDB.comparisonCount(rank) == 2)
    }

    // MARK: - Border duels

    @Test func borderAcceptPromotesToUnplacedInTargetTier() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a0 = try await RankTestDB.addGame(lib, title: "A0", tier: 1)
        try await RankTestDB.setKey(rank, a0, 1 << 30)
        let b0 = try await RankTestDB.addGame(lib, title: "B0", tier: 2)
        try await RankTestDB.setKey(rank, b0, 1 << 30)

        let prompt = try #require(try await rank.currentDuel())
        #expect(prompt.kind == .border)
        #expect(prompt.candidate == a0 && prompt.opponent == b0)
        #expect(prompt.candidateTier == 1 && prompt.opponentTier == 2)

        let outcome = try await rank.answer(winner: b0)  // top of lower tier wins → promote
        guard case let .border(suggestion?) = outcome else { Issue.record("expected a suggestion"); return }
        #expect(suggestion.game == b0 && suggestion.toTier == 1 && suggestion.kind == .promote)

        try await rank.acceptBorderSuggestion(suggestion)
        let snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.unplaced(snap, tier: 1) == [b0])            // promoted, unplaced (re-queued)
        #expect(snap.slice(for: 2)?.placed.isEmpty == true)           // left tier 2
        #expect(Consistency.checkInvariants(snap).isEmpty)
    }

    @Test func borderDismissNotReAskedImmediately() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a0 = try await RankTestDB.addGame(lib, title: "A0", tier: 1)
        try await RankTestDB.setKey(rank, a0, 1 << 30)
        let b0 = try await RankTestDB.addGame(lib, title: "B0", tier: 2)
        try await RankTestDB.setKey(rank, b0, 1 << 30)

        let prompt = try #require(try await rank.currentDuel())
        #expect(prompt.kind == .border)
        let outcome = try await rank.answer(winner: b0)
        guard case let .border(suggestion?) = outcome else { Issue.record("expected a suggestion"); return }

        try await rank.dismissBorderSuggestion(suggestion)
        // The only refine candidate is this dismissed border → nothing to duel.
        #expect(try await rank.currentDuel() == nil)
        // The game did not move.
        let snap = try await RankTestDB.snapshot(rank)
        #expect(RankTestDB.placedOrder(snap, tier: 2) == [b0])
    }

    // MARK: - Disputes (contradiction detection)

    @Test func contradictionsSurfaceACycleInTheLog() async throws {
        let (_, lib, rank) = try await RankTestDB.make()
        let a = try await RankTestDB.addGame(lib, title: "A", tier: 1)
        let b = try await RankTestDB.addGame(lib, title: "B", tier: 1)
        let c = try await RankTestDB.addGame(lib, title: "C", tier: 1)
        // Log a cycle A>B, B>C, C>A directly.
        try await rank.dbWriter.write { db in
            _ = try RankingStore.insertComparison(winner: a, loser: b, context: "refine", db)
            _ = try RankingStore.insertComparison(winner: b, loser: c, context: "refine", db)
            _ = try RankingStore.insertComparison(winner: c, loser: a, context: "refine", db)
        }
        let disputes = try await rank.contradictions()
        #expect(disputes.count == 1)
        #expect(Set(disputes.first?.games ?? []) == Set([a, b, c]))
    }
}
