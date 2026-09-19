import Foundation
import Testing
@testable import VGN

/// Per-component tests (PLAN §7b: each component independently testable).
struct RecommendationComponentTests {

    // MARK: - Score from rank

    @Test func rankScoresPercentileAndUnplacedMidpoint() throws {
        let snapshot = RankSnapshot(tiers: [
            TierSlice(tier: 1, sort: 0, placed: [RankedItem(id: 10, key: 100), RankedItem(id: 11, key: 200)]),
            TierSlice(tier: 2, sort: 1, placed: [RankedItem(id: 12, key: 100)], unplaced: [13]),
        ])
        let scores = TasteScoring.rankScores(snapshot: snapshot)
        // #1 highest, monotonic down.
        #expect(scores[10]! > scores[11]!)
        #expect(scores[11]! > scores[12]!)
        #expect(scores[10]! > 0.7 && scores[12]! < 0.3)
        // Unplaced game in tier 2 takes that tier's midpoint (= the sole placed one).
        #expect(abs(scores[13]! - scores[12]!) < 0.0001)
    }

    // MARK: - Shrunk trait affinity

    @Test func traitAffinityShrinksWeakEvidenceMore() throws {
        // mean = 0.5. Trait X seen once at 1.0; trait Y seen 3× at 1.0.
        var ranked = [
            Rec.ranked(1, score: 1.0, [Rec.trait(.keyword, "X")]),
            Rec.ranked(2, score: 1.0, [Rec.trait(.keyword, "Y")]),
            Rec.ranked(3, score: 1.0, [Rec.trait(.keyword, "Y")]),
            Rec.ranked(4, score: 1.0, [Rec.trait(.keyword, "Y")]),
        ]
        ranked += (5...8).map { Rec.ranked(GameID($0), score: 0.0) }
        let profile = TraitProfile(ranked: ranked, weights: RecommendationWeights())
        #expect(abs(profile.mean - 0.5) < 0.0001)
        let liftX = profile.lift(TraitKey(.keyword, "X"))
        let liftY = profile.lift(TraitKey(.keyword, "Y"))
        #expect(liftY > liftX)                 // more evidence ⇒ larger lift
        #expect(abs(liftX - 0.1) < 0.0001)     // (1·1 + 4·0.5)/5 − 0.5 = 0.1
        // Negative evidence counts: a trait only on low-ranked games has negative lift.
        let low = TraitProfile(ranked: [
            Rec.ranked(1, score: 0.1, [Rec.trait(.keyword, "Z")]),
            Rec.ranked(2, score: 0.1, [Rec.trait(.keyword, "Z")]),
            Rec.ranked(3, score: 0.9),
            Rec.ranked(4, score: 0.9),
        ], weights: RecommendationWeights())
        #expect(low.lift(TraitKey(.keyword, "Z")) < 0)
    }

    // MARK: - Time fit

    @Test func timeFitInsideFalloffAndHardExclusion() throws {
        let w = RecommendationWeights()
        // "By Length" shelves at the default pace (8 h/week ⇒ edges 4 / 10 / 40 / 80).
        // One Evening: under 4 h — open below, hard limit 4 × 1.5 = 6 h.
        let evening = TimeBracket(shelf: .evening)
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(3), bracket: evening, weights: w).fit == 1)
        let edge = TimeFit.evaluate(estimateSeconds: Rec.hours(5), bracket: evening, weights: w)
        #expect(edge.fit > 0 && edge.fit < 1 && !edge.excluded)
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(8), bracket: evening, weights: w).excluded)

        // A Few Weeks: 10–40 h — hard limit 40 × 1.5 = 60 h.
        let fewWeeks = TimeBracket(shelf: .fewWeeks)
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(30), bracket: fewWeeks, weights: w).fit == 1)
        let short = TimeFit.evaluate(estimateSeconds: Rec.hours(5), bracket: fewWeeks, weights: w)
        #expect(short.fit >= w.timeShortFloor && short.fit < 1 && !short.excluded)
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(70), bracket: fewWeeks, weights: w).excluded)

        // Epics: 80 h and more — unbounded upper, never excluded.
        let epics = TimeBracket(shelf: .epic)
        #expect(!TimeFit.evaluate(estimateSeconds: Rec.hours(200), bracket: epics, weights: w).excluded)
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(100), bracket: epics, weights: w).fit == 1)
        // Open below One Evening: a very short game still fits fully (no lower bound).
        #expect(TimeFit.evaluate(estimateSeconds: Rec.hours(1), bracket: evening, weights: w).fit == 1)
    }

    // MARK: - Crowd prior

    @Test func crowdWeightDecaysWithRankedCount() throws {
        let w = RecommendationWeights()
        let few = CrowdPrior.weight(rating: 80, ratingCount: 1000, rankedCount: 10, weights: w)
        let many = CrowdPrior.weight(rating: 80, ratingCount: 1000, rankedCount: 200, weights: w)
        #expect(few > many)
        #expect(CrowdPrior.weight(rating: nil, ratingCount: 1000, rankedCount: 10, weights: w) == 0)
        #expect(CrowdPrior.score(rating: 90) == 0.9)
        #expect(CrowdPrior.score(rating: nil) == nil)
    }

    // MARK: - Direct links: similar in either direction, F-tier subtracts

    @Test func directLinksSimilarBidirectionalAndSigned() throws {
        let ranked = [
            Rec.ranked(1, score: 0.95, igdbID: 111),   // loved; candidate lists it as similar
            Rec.ranked(2, score: 0.05, igdbID: 222),   // hated; lists the candidate as similar
        ]
        let candidate = Rec.candidate(100, traits: [Rec.trait(.similar, "111")], igdbID: 900)
        // Ranked game 3 lists the candidate (igdb 900) as similar.
        let ranked2 = ranked + [Rec.ranked(3, score: 0.05, igdbID: 222, [Rec.trait(.similar, "900")])]
        let (score, links) = DirectLinks.evaluate(candidate: candidate, ranked: ranked2,
                                                  weights: RecommendationWeights())
        // Positive link to game 1, negative link to game 3.
        #expect(links.contains { $0.exemplar == 1 && $0.contribution > 0 })
        #expect(links.contains { $0.exemplar == 3 && $0.contribution < 0 })
        _ = score
    }
}
