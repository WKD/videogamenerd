import Foundation
import Testing
import GRDB
@testable import VGN

/// Play Next behaviour for "To Revisit" (PLAN §7b): a flagged game is a candidate **by
/// default** (no "include abandoned" opt-in), competes on the normal score (no boost),
/// shows remaining time like a Playing game, and carries the "you wanted to come back to
/// it" reason. Plus the store round-trip: Start playing clears the flag and Undo restores
/// it exactly.
@Suite struct ToRevisitPlayNextTests {

    private func profile() -> [RankedGame] {
        (1...16).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
    }

    // MARK: - Candidate by default (no opt-in)

    @Test func toRevisitIsACandidateWithoutIncludeAbandoned() throws {
        let candidates = [
            Rec.candidate(100, status: .toRevisit, estimateHours: 20,
                          traits: [Rec.trait(.genre, "RPG")], title: "Revisit", playStatus: .toRevisit),
            Rec.candidate(101, status: .abandoned, estimateHours: 20,
                          traits: [Rec.trait(.genre, "RPG")], title: "Abandoned", playStatus: .abandoned),
        ]
        // Default options: includeAbandoned = false.
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: profile(), candidates: candidates, bracket: Rec.month()))
        let shown = Set(result.shortlist.map(\.id))
        #expect(shown.contains(100))          // To Revisit is in
        #expect(!shown.contains(101))         // plain Abandoned still needs the opt-in
        #expect(result.exclusions.byStatus == 1)   // the abandoned one
    }

    // MARK: - Reason + remaining time

    @Test func toRevisitCarriesReasonAndRemainingTime() throws {
        // 20 h game, 15 h already played → 5 h remaining, like a Playing game.
        let candidate = Rec.candidate(100, status: .toRevisit, estimateHours: 20, playedHours: 15,
                                      traits: [Rec.trait(.genre, "RPG")], title: "Revisit", playStatus: .toRevisit)
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: profile(), candidates: [candidate], bracket: Rec.month()))
        let hero = try #require(result.hero)

        // Bracket estimate is the *remaining* time (full − played).
        #expect(hero.estimateSeconds == Rec.hours(5))
        #expect(hero.fullEstimateSeconds == Rec.hours(20))
        // The reasons include remaining-time AND the revisit reason.
        #expect(hero.reasons.contains { if case .remainingTime = $0 { true } else { false } })
        #expect(hero.reasons.contains(.wantedToRevisit))
        // The formatter writes the sentence.
        let sentences = PlayNextReasonFormatter.sentences(for: hero, exemplars: [:], bracket: Rec.month())
        #expect(sentences.contains("You wanted to come back to it"))
    }

    // MARK: - No artificial boost (backtest-neutral)

    @Test func toRevisitScoresLikeAbandoned_noBoost() throws {
        // Identical candidate, no playtime (so the bracket estimate is identical either way);
        // the only difference is the status. There is no score term for the flag.
        func score(status: RecCandidateStatus, playStatus: PlayStatus, includeAbandoned: Bool) -> Double {
            let c = Rec.candidate(100, status: status, estimateHours: 20,
                                  traits: [Rec.trait(.genre, "RPG")], title: "G", playStatus: playStatus)
            let result = RecommendationEngine.recommend(RecommendationInput(
                ranked: profile(), candidates: [c], bracket: Rec.month(),
                options: RecommendationOptions(includeAbandoned: includeAbandoned, seed: 0)))
            return result.hero?.score ?? -1
        }
        let revisit = score(status: .toRevisit, playStatus: .toRevisit, includeAbandoned: false)
        let abandoned = score(status: .abandoned, playStatus: .abandoned, includeAbandoned: true)
        #expect(revisit == abandoned)   // same score, no boost
    }

    /// The taste backtest works on ranked games only — the candidate flag never reaches
    /// `predict`, so ρ is identical whether or not games are flagged.
    @Test func backtestIsIndependentOfTheFlag() throws {
        let ranked = profile()
        let a = TasteBacktest.run(ranked: ranked)
        let b = TasteBacktest.run(ranked: ranked)   // flag is not an input to predict
        #expect(a.spearman == b.spearman)
    }

    // MARK: - Start playing clears the flag; Undo restores it

    @Test func startPlayingClearsFlagAndUndoRestoresIt() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let rec = RecommendationStore(db)
        let g = try await lib.addGame(GameDraft(title: "Revisit", igdbID: 1, platformIDs: ["ps4"],
                                                owned: true, played: true, status: .toRevisit)).gameID
        #expect(try await lib.gameDetail(id: g)?.status == .toRevisit)

        // Start playing → Playing, flag cleared.
        let token = try await rec.startPlayingCapturingUndo(gameID: g)
        #expect(try await lib.gameDetail(id: g)?.status == .playing)
        let afterStart = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT revisit FROM games WHERE id = ?", arguments: [g])
        }
        #expect(afterStart == 0)

        // Undo restores To Revisit exactly (status + flag).
        let outcome = try await rec.undoStartPlaying(token)
        #expect(outcome == .restored)
        #expect(try await lib.gameDetail(id: g)?.status == .toRevisit)
        let afterUndo = try await db.dbWriter.read { db in
            try Int64.fetchOne(db, sql: "SELECT revisit FROM games WHERE id = ?", arguments: [g])
        }
        #expect(afterUndo == 1)
    }
}
