import Foundation
import Testing
@testable import VGN

/// The Batocera-favourite boost in Play Next's regular picks (PLAN §15): a small additive
/// term for an **unplayed** library game the owner ★ favourited on his box — it reorders
/// near-ties, never overturns a clearly better fit, is gone once the game is played, and
/// vanishes when the flag is cleared (un-favourited on the next sync). Pure engine — no DB.
/// Jitter is disabled so the near-tie assertions are exact.
struct RecommendationFavouriteTests {

    /// A profile where "RPG" is strongly liked, so an RPG scores well above a neutral game —
    /// a gap larger than the favourite bonus.
    private func rpgProfile() -> [RankedGame] {
        var ranked = (1...15).map { Rec.ranked(GameID($0), score: 0.92, [Rec.trait(.genre, "RPG")]) }
        for i in 16...25 { ranked.append(Rec.ranked(GameID(i), score: 0.2, [Rec.trait(.genre, "Sports")])) }
        return ranked
    }
    private var noJitter: RecommendationWeights {
        var w = RecommendationWeights(); w.rotationMagnitude = 0; return w
    }

    @Test func theBoostIsExactlyTheBonusForAnUnplayedFavourite() throws {
        let ranked = rpgProfile()
        func score(fav: Bool) -> Double {
            let c = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                                  igdbID: 500, title: "Fav", isBatoceraFavourite: fav)
            return RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [c], bracket: Rec.month(),
                options: RecommendationOptions(seed: 0), weights: noJitter))
                .shortlist.first { $0.id == 100 }!.score
        }
        #expect(abs((score(fav: true) - score(fav: false)) - RecommendationWeights().batoceraFavouriteBonus) < 1e-9)
    }

    @Test func theFavouriteReordersANearTie() throws {
        let ranked = rpgProfile()
        // Two identical RPG backlog candidates; only A is a Batocera favourite.
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 500, title: "Fav", isBatoceraFavourite: true)
        let b = Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 501, title: "Plain")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [a, b], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0), weights: noJitter))
        #expect(result.hero?.id == 100)
        let sa = result.shortlist.first { $0.id == 100 }!.score
        let sb = result.shortlist.first { $0.id == 101 }!.score
        #expect(sa > sb, "the favourite edges ahead of its identical twin")
    }

    @Test func theFavouriteNeverOverturnsAClearlyBetterFit() throws {
        let ranked = rpgProfile()
        // A is a favourite Sports game (disliked); B a strongly-liked RPG (not a favourite).
        let a = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "Sports")],
                              igdbID: 500, title: "FavSports", isBatoceraFavourite: true)
        let b = Rec.candidate(101, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 501, title: "GreatRPG")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [a, b], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0), weights: noJitter))
        #expect(result.hero?.id == 101)
        let sa = result.shortlist.first { $0.id == 100 }!.score
        let sb = result.shortlist.first { $0.id == 101 }!.score
        #expect(sb - sa > RecommendationWeights().batoceraFavouriteBonus, "the taste gap dwarfs the nudge")
    }

    @Test func aPlayedFavouriteGetsNoBoostAndNoReason() throws {
        let ranked = rpgProfile()
        // A `playing` favourite is already being played → no backlog boost, no reason.
        func score(status: RecCandidateStatus) -> (Double, [PlayNextReason]) {
            let c = Rec.candidate(100, status: status, estimateHours: 20,
                                  traits: [Rec.trait(.genre, "RPG")], igdbID: 500,
                                  title: "Fav", playStatus: status == .playing ? .playing : nil,
                                  isBatoceraFavourite: true)
            let s = RecommendationEngine.recommend(RecommendationInput(
                ranked: ranked, candidates: [c], bracket: Rec.month(),
                options: RecommendationOptions(includePlayedWithoutStatus: true, seed: 0),
                weights: noJitter)).shortlist.first { $0.id == 100 }!
            return (s.score, s.reasons)
        }
        let backlog = score(status: .backlog)
        let playing = score(status: .playing)
        #expect(backlog.0 > playing.0, "the boost only applies to an unplayed favourite")
        #expect(backlog.1.contains(.batoceraFavourite))
        #expect(!playing.1.contains(.batoceraFavourite))
    }

    @Test func unfavouritedGetsNoBoost() throws {
        let ranked = rpgProfile()
        let c = Rec.candidate(100, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                              igdbID: 500, title: "Plain", isBatoceraFavourite: false)
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [c], bracket: Rec.month(),
            options: RecommendationOptions(seed: 0), weights: noJitter))
        let s = try #require(result.shortlist.first { $0.id == 100 })
        #expect(!s.reasons.contains(.batoceraFavourite))
    }

    @Test func theReasonFormatsAsAFavouriteLine() {
        #expect(PlayNextReasonFormatter.sentence(for: .batoceraFavourite, exemplars: [:],
                                                 bracket: Rec.month()) == "★ a favourite on your Batocera")
    }
}
