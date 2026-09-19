import Foundation

/// The outcome of matching a library game against HLTB search candidates (PLAN §5.3).
enum HLTBMatchOutcome: Sendable, Equatable {
    /// A single clear winner — fills directly (and, in bulk mode, without asking).
    case confident(HLTBCandidate)
    /// Several plausible candidates — the user picks one (bulk mode lists these).
    case ambiguous([HLTBCandidate])
    /// Nothing scored high enough to offer.
    case notFound
}

/// Pure title matching for the HLTB fallback (PLAN §5.3): ``TitleNormalizer`` +
/// ``FuzzyMatch`` over each candidate's name and aliases, with the game's release
/// year (± 1) as the tie-breaker. Foundation-only, so every threshold is unit-tested
/// on tricky pairs (numbered sequels, "Remastered", subtitle-only differences, and
/// the same name at two different years).
enum HLTBMatcher {

    // MARK: - Thresholds (named, tested)

    /// At/above this a name is a confident textual match (mirrors ``FuzzyMatch``).
    static let confidentThreshold = FuzzyMatch.confidentThreshold        // 0.90
    /// At/above this a name is plausible enough to offer to the user.
    static let plausibleThreshold = FuzzyMatch.plausibleThreshold        // 0.74
    /// The winner must lead the runner-up by at least this (after the year tweak) to
    /// be taken as confident rather than ambiguous.
    static let ambiguityMargin = 0.05
    /// Score added when the candidate's year is within ± 1 of the game's year, and
    /// subtracted when it is off by ≥ 2 — the tie-breaker that separates same-named
    /// games from different years. Larger than ``ambiguityMargin`` so a year match
    /// can promote an otherwise-tied candidate to confident.
    static let yearMatchBoost = 0.06
    static let yearMismatchPenalty = 0.06
    /// Year distance (inclusive) treated as "the same release".
    static let yearTolerance = 1
    /// Cap on how many candidates an ambiguous result offers.
    static let maxAmbiguous = 8

    // MARK: - Scoring

    struct Scored: Sendable, Equatable {
        var candidate: HLTBCandidate
        var base: Double
        var adjusted: Double
    }

    /// Score every candidate: the best fuzzy score across its names, tweaked by the
    /// year tie-breaker. Best first; ties broken by year closeness then id for
    /// determinism.
    static func scored(title: String, year: Int?, candidates: [HLTBCandidate]) -> [Scored] {
        candidates.map { candidate -> Scored in
            let base = FuzzyMatch.bestScore(query: title, names: candidate.allNames)
            var adjusted = base
            if let year, let cy = candidate.releaseYear {
                let diff = abs(cy - year)
                if diff <= yearTolerance { adjusted += yearMatchBoost }
                else if diff >= 2 { adjusted -= yearMismatchPenalty }
            }
            return Scored(candidate: candidate, base: base, adjusted: adjusted)
        }
        .sorted { a, b in
            if a.adjusted != b.adjusted { return a.adjusted > b.adjusted }
            // Tie-break: closer year, then lower id.
            let ay = yearDistance(a.candidate.releaseYear, year)
            let by = yearDistance(b.candidate.releaseYear, year)
            if ay != by { return ay < by }
            return a.candidate.id < b.candidate.id
        }
    }

    // MARK: - Match

    /// Decide the outcome for one game.
    static func match(title: String, year: Int?, candidates: [HLTBCandidate]) -> HLTBMatchOutcome {
        let ranked = scored(title: title, year: year, candidates: candidates)
        let viable = ranked.filter { $0.base >= plausibleThreshold }
        guard let best = viable.first else { return .notFound }

        let isConfidentText = best.base >= confidentThreshold
        let clearlyAhead: Bool = {
            guard viable.count > 1 else { return true }
            return best.adjusted - viable[1].adjusted >= ambiguityMargin
        }()

        if isConfidentText && clearlyAhead {
            return .confident(best.candidate)
        }
        return .ambiguous(Array(viable.prefix(maxAmbiguous).map(\.candidate)))
    }

    private static func yearDistance(_ candidateYear: Int?, _ year: Int?) -> Int {
        guard let candidateYear, let year else { return Int.max }
        return abs(candidateYear - year)
    }
}
