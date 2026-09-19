import Foundation
import Testing
@testable import VGN

/// The opt-in "Prefer expiring PS Plus games" score term (PLAN §13.3): off by default, a
/// small additive nudge that only reorders near-ties and never overturns a clearly better
/// fit, and a "leaves with PS Plus" reason line. Pure engine — no DB. Jitter is disabled
/// (`rotationMagnitude = 0`) so the near-tie assertions are exact.
struct RecommendationSubscriptionTests {
    /// A profile where the "RPG" genre is strongly liked, so an RPG candidate scores well
    /// above a neutral one — a "clearly better" gap larger than the subscription bonus.
    private func rpgProfile() -> [RankedGame] {
        var ranked = (1...15).map { Rec.ranked(GameID($0), score: 0.92, [Rec.trait(.genre, "RPG")]) }
        for i in 16...25 { ranked.append(Rec.ranked(GameID(i), score: 0.2, [Rec.trait(.genre, "Sports")])) }
        return ranked
    }
    private var noJitter: RecommendationWeights {
        var w = RecommendationWeights(); w.rotationMagnitude = 0; return w
    }

    @Test func offByDefaultAndTheTermIsExactlyTheBonus() throws {
        let ranked = rpgProfile()
        let sub = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        func score(preferSub: Bool) -> Double {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [sub], bracket: Rec.month(),
                options: RecommendationOptions(seed: 0, preferExpiringSubscription: preferSub),
                weights: noJitter)).shortlist.first { $0.id == 100 }!.score
        }
        let off = score(preferSub: false)
        let on = score(preferSub: true)
        // Default is off (no bonus); turning it on adds exactly the bonus.
        #expect(abs((on - off) - RecommendationWeights().subscriptionBonus) < 1e-9)
    }

    @Test func theOptionReordersANearTie() throws {
        let ranked = rpgProfile()
        // Two identical RPG candidates; only A leaves with PS Plus.
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        let b = Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 501, title: "Owned")
        func hero(preferSub: Bool) -> GameID? {
            RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [a, b], bracket: Rec.month(),
                options: RecommendationOptions(seed: 0, preferExpiringSubscription: preferSub),
                weights: noJitter)).hero?.id
        }
        // Off: the tie breaks by id (100 before 101). On: the PS Plus game is preferred —
        // and since it was a tie, it is now strictly ahead.
        let onResult = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [a, b], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0, preferExpiringSubscription: true),
            weights: noJitter))
        #expect(onResult.hero?.id == 100)
        let scoreA = onResult.shortlist.first { $0.id == 100 }!.score
        let scoreB = onResult.shortlist.first { $0.id == 101 }!.score
        #expect(scoreA > scoreB, "the PS Plus game edges ahead of its identical twin")
        _ = hero
    }

    @Test func theOptionNeverOverturnsAClearlyBetterFit() throws {
        let ranked = rpgProfile()
        // B is a strongly-liked RPG; A is a neutral Sports game that leaves with PS Plus.
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "Sports")],
                              igdbID: 500, title: "PlusSports", ownedOnlyViaSubscription: true)
        let b = Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 501, title: "GreatRPG")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [a, b], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0, preferExpiringSubscription: true),
            weights: noJitter))
        // The clearly-better RPG stays the hero even with the option on.
        #expect(result.hero?.id == 101)
        let scoreA = result.shortlist.first { $0.id == 100 }!.score
        let scoreB = result.shortlist.first { $0.id == 101 }!.score
        #expect(scoreB - scoreA > RecommendationWeights().subscriptionBonus,
                "the taste gap dwarfs the nudge")
    }

    @Test func aPlusOnlyGameCarriesTheLeavesWithSubscriptionReason() throws {
        let ranked = rpgProfile()
        let sub = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                igdbID: 500, title: "PlusOnly", ownedOnlyViaSubscription: true)
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [sub], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0), weights: noJitter))
        let suggestion = try #require(result.shortlist.first { $0.id == 100 })
        #expect(suggestion.reasons.contains(.leavesWithSubscription))
        // The UI formats it as "Leaves with PS Plus".
        #expect(PlayNextReasonFormatter.sentence(for: .leavesWithSubscription,
                                                 exemplars: [:], bracket: Rec.month()) == "Leaves with PS Plus")
    }
}
