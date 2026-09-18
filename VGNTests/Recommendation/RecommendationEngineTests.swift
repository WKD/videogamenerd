import Foundation
import Testing
@testable import VGN

/// The PLAN §7b acceptance tests over synthetic libraries, plus per-component
/// checks. Pure engine — no DB.
struct RecommendationEngineTests {

    // MARK: - Acceptance: the souls-like lover gets the unplayed souls-like

    @Test func soulsLikeLoverGetsTheSoulsLike() throws {
        // Three souls-likes in S (all share the "souls-like" keyword) + assorted
        // lower-ranked games so the profile has a mean well below them.
        var ranked: [RankedGame] = [
            Rec.ranked(1, score: 0.97, [Rec.trait(.keyword, "souls-like"), Rec.trait(.developer, "FromSoftware")]),
            Rec.ranked(2, score: 0.93, [Rec.trait(.keyword, "souls-like"), Rec.trait(.developer, "FromSoftware")]),
            Rec.ranked(3, score: 0.90, [Rec.trait(.keyword, "souls-like")]),
        ]
        for i in 4...15 { ranked.append(Rec.ranked(GameID(i), score: 0.5 - Double(i) * 0.02,
                                                    [Rec.trait(.genre, "Sports")])) }
        let candidates = [
            Rec.candidate(100, estimateHours: 30, traits: [Rec.trait(.keyword, "souls-like")], title: "Unplayed Souls"),
            Rec.candidate(101, estimateHours: 25, traits: [Rec.trait(.genre, "Sports")], title: "Another Sports Game"),
        ]
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: ranked, candidates: candidates, bracket: Rec.month()))
        #expect(result.hero?.id == 100)
    }

    // MARK: - Acceptance: a 60 h JRPG never appears in "An evening"

    @Test func longJRPGNeverInAnEvening() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
        let candidates = [
            Rec.candidate(100, estimateHours: 60, traits: [Rec.trait(.genre, "RPG")], title: "Long JRPG"),
            Rec.candidate(101, estimateHours: 3, traits: [Rec.trait(.genre, "RPG")], title: "Short Game"),
        ]
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: ranked, candidates: candidates, bracket: Rec.evening()))
        let shown = Set(result.shortlist.map(\.id))
        #expect(!shown.contains(100))
        #expect(result.hero?.id == 101)
        #expect(result.exclusions.byTime >= 1)
    }

    // MARK: - Acceptance: one S-tier outlier never crowns a genre (shrinkage)

    @Test func singleOutlierBarelyMovesItsTrait() throws {
        // One racing game in S; three souls-likes in S. Both candidates fit the
        // bracket, but "souls-like" (n=3) outweighs "racing" (n=1, shrunk).
        var ranked: [RankedGame] = [
            Rec.ranked(1, score: 0.98, [Rec.trait(.genre, "Racing")]),
            Rec.ranked(2, score: 0.96, [Rec.trait(.keyword, "souls-like")]),
            Rec.ranked(3, score: 0.95, [Rec.trait(.keyword, "souls-like")]),
            Rec.ranked(4, score: 0.94, [Rec.trait(.keyword, "souls-like")]),
        ]
        for i in 5...16 { ranked.append(Rec.ranked(GameID(i), score: 0.35, [Rec.trait(.genre, "Puzzle")])) }
        let candidates = [
            Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "Racing")], title: "Racing"),
            Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.keyword, "souls-like")], title: "Souls"),
        ]
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: ranked, candidates: candidates, bracket: Rec.month()))
        #expect(result.hero?.id == 101)     // the well-evidenced trait wins
    }

    // MARK: - Acceptance: a game similar to an F-tier game is pushed down

    @Test func similarToDislikedGameIsPushedDown() throws {
        var ranked: [RankedGame] = [
            Rec.ranked(1, score: 0.08, igdbID: 1, [Rec.trait(.genre, "Shooter")]),   // an F-tier game
        ]
        for i in 2...16 { ranked.append(Rec.ranked(GameID(i), score: 0.5, [Rec.trait(.genre, "Various")])) }
        // Two identical candidates except A is `similar` to the F-tier game (id 1).
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.similar, "1")],
                              igdbID: 500, title: "SimilarToF")
        let b = Rec.candidate(101, estimateHours: 20, traits: [], igdbID: 501, title: "Neutral")
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: ranked, candidates: [a, b], bracket: Rec.month(),
                                options: RecommendationOptions(seed: 0)))
        let scoreA = result.shortlist.first { $0.id == 100 }!.score
        let scoreB = result.shortlist.first { $0.id == 101 }!.score
        #expect(scoreA < scoreB)
        #expect(result.hero?.id == 101)
    }

    // MARK: - Acceptance: 5 ranked games ⇒ crowd prior dominates, strength weak

    @Test func fewRankedGamesLeanOnCrowdAndAreWeak() throws {
        let ranked = (1...5).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
        let candidates = [
            Rec.candidate(100, estimateHours: 20, igdbID: 10, rating: 95, ratingCount: 2000, title: "Acclaimed"),
            Rec.candidate(101, estimateHours: 20, igdbID: 11, rating: 60, ratingCount: 2000, title: "Mediocre"),
        ]
        let result = RecommendationEngine.recommend(
            RecommendationInput(ranked: ranked, candidates: candidates, bracket: Rec.month()))
        #expect(result.hero?.id == 100)                 // higher crowd rating wins
        #expect(result.hero?.matchStrength == .weak)    // thin evidence ⇒ weak
    }

    // MARK: - Acceptance: determinism + re-roll only touches near-ties

    @Test func deterministicAndReRollTouchesOnlyNearTies() throws {
        // A clear winner (strong link) + two near-tie also-rans.
        var ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
        ranked[0] = Rec.ranked(1, score: 0.98, igdbID: 1, [Rec.trait(.franchise, "Zelda")])
        let clearWinner = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.franchise, "Zelda")],
                                        igdbID: 500, title: "Zelda-like")
        let tieA = Rec.candidate(101, estimateHours: 20, igdbID: 501, rating: 80, ratingCount: 100, title: "A")
        let tieB = Rec.candidate(102, estimateHours: 20, igdbID: 502, rating: 80, ratingCount: 100, title: "B")
        func run(seed: UInt64) -> PlayNextResult {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [clearWinner, tieA, tieB], bracket: Rec.month(),
                options: RecommendationOptions(seed: seed)))
        }
        // Deterministic for a fixed seed.
        #expect(run(seed: 7) == run(seed: 7))
        // The clear winner is stable across seeds…
        for seed in UInt64(0)..<20 { #expect(run(seed: seed).hero?.id == 100) }
        // …but the two near-ties reorder for at least one seed.
        var orders: Set<[GameID]> = []
        for seed in UInt64(0)..<20 {
            let alt = run(seed: seed).alternatives.map(\.id)
            orders.insert(alt)
        }
        #expect(orders.count >= 2)
    }

    // MARK: - Feedback: snooze / never

    @Test func snoozeAndNeverRespected() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5) }
        let candidates = [
            Rec.candidate(100, estimateHours: 20, title: "Nevered"),
            Rec.candidate(101, estimateHours: 20, title: "Snoozed"),
            Rec.candidate(102, estimateHours: 20, title: "Fine"),
        ]
        let now = 1_000_000.0
        let feedback = RecFeedbackState(snoozedUntil: [101: now + 100], never: [100])
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: Rec.month(), feedback: feedback,
            options: RecommendationOptions(seed: 0, now: now)))
        let shown = Set(result.shortlist.map(\.id))
        #expect(!shown.contains(100) && !shown.contains(101))
        #expect(shown.contains(102))
        #expect(result.exclusions.byFeedback == 2)

        // A past snooze is eligible again.
        let expired = RecFeedbackState(snoozedUntil: [101: now - 100])
        let result2 = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: Rec.month(), feedback: expired,
            options: RecommendationOptions(seed: 0, now: now)))
        #expect(Set(result2.shortlist.map(\.id)).contains(101))
    }

    // MARK: - Playing uses remaining time

    @Test func playingGameUsesRemainingTime() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5) }
        // 20 h game, 18 h played → 2 h remaining fits "an evening".
        let playing = Rec.candidate(100, status: .playing, estimateHours: 20, playedHours: 18,
                                    title: "Nearly Done", playStatus: .playing)
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [playing], bracket: Rec.evening()))
        #expect(result.hero?.id == 100)
        #expect(result.hero?.estimateSeconds == Rec.hours(2))
        #expect(result.hero?.reasons.contains { if case .remainingTime = $0 { true } else { false } } == true)
    }

    // MARK: - Unknown-length lane

    @Test func noEstimateGoesToUnknownLengthLane() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5) }
        let candidates = [
            Rec.candidate(100, estimateHours: nil, title: "No Estimate"),
            Rec.candidate(101, estimateHours: 20, title: "Has Estimate"),
        ]
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: Rec.month()))
        #expect(result.unknownLength.map(\.id) == [100])
        #expect(result.hero?.id == 101)
        #expect(result.exclusions.unknownLength == 1)
    }

    // MARK: - Candidate rules

    @Test func abandonedAndPlayedUnknownAreOptIn() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5) }
        let candidates = [
            Rec.candidate(100, status: .abandoned, estimateHours: 20, title: "Abandoned"),
            Rec.candidate(101, status: .playedUnknown, estimateHours: 20, title: "PlayedNoStatus"),
            Rec.candidate(102, status: .backlog, estimateHours: 20, title: "Backlog"),
        ]
        // Default: both excluded.
        let base = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: Rec.month()))
        #expect(Set(base.shortlist.map(\.id)) == [102])
        #expect(base.exclusions.byStatus == 2)

        // Opt in to both.
        let opted = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: candidates, bracket: Rec.month(),
            options: RecommendationOptions(includeAbandoned: true, includePlayedWithoutStatus: true)))
        #expect(Set(opted.shortlist.map(\.id)) == [100, 101, 102])
    }

    @Test func noMetadataStillEligibleOnTimeFitAndFlagged() throws {
        let ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5) }
        let manual = Rec.candidate(100, estimateHours: 3, igdbID: nil, hasMetadata: false, title: "Obscure ROM")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [manual], bracket: Rec.evening()))
        #expect(result.hero?.id == 100)
        #expect(result.hero?.hasMetadata == false)
        #expect(result.hero?.reasons.contains(.noMetadata) == true)
    }

    // MARK: - Reasons cite the right exemplars

    @Test func reasonsCiteExemplars() throws {
        var ranked = (1...20).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
        ranked[0] = Rec.ranked(1, score: 0.97, igdbID: 1,
                               [Rec.trait(.franchise, "Souls"), Rec.trait(.developer, "FromSoftware")])
        ranked[1] = Rec.ranked(2, score: 0.95, igdbID: 2,
                               [Rec.trait(.franchise, "Souls"), Rec.trait(.developer, "FromSoftware")])
        let candidate = Rec.candidate(100, estimateHours: 30,
                                      traits: [Rec.trait(.franchise, "Souls"), Rec.trait(.developer, "FromSoftware")],
                                      igdbID: 500, title: "New Souls")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [candidate], bracket: Rec.month()))
        let reasons = try #require(result.hero?.reasons)
        // Cites the shared franchise with a ranked exemplar (id 1 or 2).
        #expect(reasons.contains { if case let .sharedFranchise(value, with) = $0 { value == "Souls" && (with == 1 || with == 2) } else { false } })
        #expect(reasons.contains { if case let .sameDeveloper(name, _) = $0 { name == "FromSoftware" } else { false } })
        #expect(reasons.contains { if case .fitsBracket = $0 { true } else { false } })
    }
}
