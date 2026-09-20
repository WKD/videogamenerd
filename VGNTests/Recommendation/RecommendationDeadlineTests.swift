import Foundation
import Testing
@testable import VGN

/// The PS Plus deadline ramp applied to library candidates in the engine (PLAN §16): a set
/// date lifts a finishable PS Plus game more than the plain constant, the deadline reason
/// renders, a past date gives no boost, and the ramp never overturns a clearly better fit.
struct RecommendationDeadlineTests {
    private func rpgProfile() -> [RankedGame] {
        var ranked = (1...15).map { Rec.ranked(GameID($0), score: 0.92, [Rec.trait(.genre, "RPG")]) }
        for i in 16...25 { ranked.append(Rec.ranked(GameID(i), score: 0.2, [Rec.trait(.genre, "Sports")])) }
        return ranked
    }
    private var noJitter: RecommendationWeights {
        var w = RecommendationWeights(); w.rotationMagnitude = 0; return w
    }

    @Test func aNearDeadlineLiftsAFinishablePlusGameMoreThanTheConstant() throws {
        let ranked = rpgProfile()
        let sub = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        func score(_ options: RecommendationOptions) -> Double {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [sub], bracket: Rec.month(),
                options: options, weights: noJitter)).shortlist.first { $0.id == 100 }!.score
        }
        let constant = score(RecommendationOptions(seed: 0, preferExpiringSubscription: true))
        let dated = score(RecommendationOptions(seed: 0, psPlusMonthsLeft: 2,
                                                psPlusPace: PlayPace(hoursPerWeek: 10)))
        #expect(dated > constant)   // a finishable game near the deadline beats the flat nudge
    }

    @Test func deadlineReasonRenders() throws {
        let ranked = rpgProfile()
        let sub = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [sub], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0, psPlusMonthsLeft: 9,
                                           psPlusPace: PlayPace(hoursPerWeek: 10)),
            weights: noJitter))
        let suggestion = try #require(result.shortlist.first { $0.id == 100 })
        let hasDeadline = suggestion.reasons.contains {
            if case .leavesWithSubscriptionDeadline = $0 { return true }
            return false
        }
        #expect(hasDeadline)
    }

    @Test func aPastDateGivesNoBoost() throws {
        let ranked = rpgProfile()
        let sub = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        func score(_ options: RecommendationOptions) -> Double {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [sub], bracket: Rec.month(),
                options: options, weights: noJitter)).shortlist.first { $0.id == 100 }!.score
        }
        // A past date (negative months) contributes nothing; equals the no-term baseline.
        let past = score(RecommendationOptions(seed: 0, psPlusMonthsLeft: -3))
        let none = score(RecommendationOptions(seed: 0))
        #expect(abs(past - none) < 1e-9)
    }

    @Test func deadlineNeverOverturnsAClearlyBetterFit() throws {
        let ranked = rpgProfile()
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "Sports")],
                              igdbID: 500, title: "PlusSports", ownedOnlyViaSubscription: true)
        let b = Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 501, title: "GreatRPG")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [a, b], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0, psPlusMonthsLeft: 0.1,
                                           psPlusPace: PlayPace(hoursPerWeek: 20)),
            weights: noJitter))
        #expect(result.hero?.id == 101)   // the strongly-liked RPG stays ahead
    }
}
