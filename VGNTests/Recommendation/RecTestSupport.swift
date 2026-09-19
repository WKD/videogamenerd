import Foundation
@testable import VGN

/// Concise builders for the recommendation engine tests (synthetic libraries).
enum Rec {
    static func hours(_ h: Double) -> Int { Int(h * 3600) }

    static func trait(_ kind: GameTraitKind, _ value: String) -> GameTrait {
        GameTrait(kind: kind, value: value)
    }

    static func ranked(
        _ id: GameID, score: Double, igdbID: Int64? = nil, _ traits: [GameTrait] = []
    ) -> RankedGame {
        RankedGame(id: id, igdbID: igdbID, score: score, traits: traits)
    }

    static func candidate(
        _ id: GameID,
        status: RecCandidateStatus = .backlog,
        estimateHours: Double? = nil,
        completionistHours: Double? = nil,
        playedHours: Double? = nil,
        traits: [GameTrait] = [],
        igdbID: Int64? = nil,
        rating: Double? = nil,
        ratingCount: Int? = nil,
        hasMetadata: Bool = true,
        title: String = "Candidate",
        playStatus: PlayStatus? = nil,
        ownedOnlyViaSubscription: Bool = false,
        isBatoceraFavourite: Bool = false
    ) -> Candidate {
        Candidate(
            id: id,
            igdbID: igdbID,
            traits: traits,
            estimateSeconds: estimateHours.map { hours($0) },
            completionistSeconds: completionistHours.map { hours($0) },
            myPlaytimeSeconds: playedHours.map { hours($0) },
            status: status,
            igdbRating: rating,
            ratingCount: ratingCount,
            hasMetadata: hasMetadata,
            title: title,
            playStatus: playStatus,
            ownedOnlyViaSubscription: ownedOnlyViaSubscription,
            isBatoceraFavourite: isBatoceraFavourite)
    }

    // "By Length" brackets at the default pace (8 h/week ⇒ edges 4 / 10 / 40 / 80).
    // The play style defaults to `.storyFirst` (t = 0) so a candidate's personal length
    // equals its raw `normally` estimate — the engine numerics these suites assert on.
    static func evening(completionist: Bool = false, style: PlayStyle = .storyFirst) -> TimeBracket {
        TimeBracket(shelf: .evening, playStyle: style, completionist: completionist)   // under 4 h
    }
    /// A mid bracket (A Few Weeks: 10–40 h) — the successor to the old "A month".
    static func month(completionist: Bool = false, style: PlayStyle = .storyFirst) -> TimeBracket {
        TimeBracket(shelf: .fewWeeks, playStyle: style, completionist: completionist)
    }
}
