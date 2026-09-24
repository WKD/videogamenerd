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
/// year (± 1) as the tie-breaker. Wave 21 (D2): the text score is the **max** of the
/// order-sensitive ``FuzzyMatch`` and the order-free ``TitleTokenSet`` (same words in
/// another order / segmentation — "The Beast Within: A Gabriel Knight Mystery" vs
/// "Gabriel Knight II: The Beast Within"), taken against the library title **and** the
/// ladder query that produced the candidates. Thresholds unchanged. Foundation-only, so every threshold is unit-tested
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
        /// The candidate's platform list intersects the library game's effective platforms
        /// (D2 tie-breaker). Always false when no library slugs were supplied.
        var platformMatch: Bool = false
    }

    /// Score every candidate: the best fuzzy score across its names, tweaked by the
    /// year tie-breaker. Best first; ties broken by **platform overlap** (D2), then year
    /// closeness, then id for determinism. `librarySlugs` are the game's *effective*
    /// platforms (`LibraryQuery.effectivePlatformsSQL`); empty ⇒ platform plays no part.
    static func scored(title: String, year: Int?, candidates: [HLTBCandidate],
                       librarySlugs: Set<String> = [], query: String? = nil) -> [Scored] {
        candidates.map { candidate -> Scored in
            let base = textScore(title: title, query: query, names: candidate.allNames)
            var adjusted = base
            if let year, let cy = candidate.releaseYear {
                let diff = abs(cy - year)
                if diff <= yearTolerance { adjusted += yearMatchBoost }
                else if diff >= 2 { adjusted -= yearMismatchPenalty }
            }
            let platformMatch = HLTBPlatformMap.intersects(
                candidatePlatforms: candidate.platforms, librarySlugs: librarySlugs)
            return Scored(candidate: candidate, base: base, adjusted: adjusted, platformMatch: platformMatch)
        }
        .sorted { a, b in
            if a.adjusted != b.adjusted { return a.adjusted > b.adjusted }
            // Tie-break 1 (D2): a candidate on one of my platforms wins a title tie.
            if a.platformMatch != b.platformMatch { return a.platformMatch }
            // Tie-break 2: closer year, then lower id.
            let ay = yearDistance(a.candidate.releaseYear, year)
            let by = yearDistance(b.candidate.releaseYear, year)
            if ay != by { return ay < by }
            return a.candidate.id < b.candidate.id
        }
    }

    /// The text score of one candidate (wave 21 D2): `max(FuzzyMatch, TitleTokenSet)`
    /// against the library `title`, and — when the ladder searched a different, cleaned
    /// `query` — against that query too (so an edition-stripped rung can still match the
    /// base entry exactly, as before).
    static func textScore(title: String, query: String?, names: [String]) -> Double {
        var texts = [title]
        if let query, query.caseInsensitiveCompare(title) != .orderedSame { texts.append(query) }
        var best = 0.0
        for text in texts {
            best = max(best, FuzzyMatch.bestScore(query: text, names: names),
                       TitleTokenSet.bestScore(query: text, names: names))
        }
        return best
    }

    // MARK: - Match

    /// Decide the outcome for one game. `librarySlugs` are the game's effective platforms
    /// — a **tie-breaker only** (D2): among candidates whose titles are equally good it
    /// prefers the one on one of my platforms (and the closest year), but it never promotes
    /// a worse title match over a better one, and never auto-picks when two candidates stay
    /// tied after platform + year (→ still ambiguous).
    static func match(title: String, year: Int?, candidates: [HLTBCandidate],
                      librarySlugs: Set<String> = [], query: String? = nil) -> HLTBMatchOutcome {
        let ranked = scored(title: title, year: year, candidates: candidates,
                            librarySlugs: librarySlugs, query: query)
        let viable = ranked.filter { $0.base >= plausibleThreshold }
        guard let best = viable.first else { return .notFound }

        // The "equally good title" cluster: candidates within the ambiguity margin of the
        // top adjusted (year) score. Platform + year only ever break a tie *inside* it.
        let cluster = viable.filter { best.adjusted - $0.adjusted < ambiguityMargin }
        let isConfidentText = best.base >= confidentThreshold
        let uniqueInCluster: Bool = {
            guard cluster.count > 1 else { return true }
            // `best` is already the cluster head after the platform+year sort. It is a
            // clear winner only if the runner-up differs on the platform or year tie-break.
            let second = cluster[1]
            if best.platformMatch != second.platformMatch { return true }
            return yearDistance(best.candidate.releaseYear, year) < yearDistance(second.candidate.releaseYear, year)
        }()

        if isConfidentText && uniqueInCluster {
            return .confident(best.candidate)
        }
        return .ambiguous(Array(viable.prefix(maxAmbiguous).map(\.candidate)))
    }

    private static func yearDistance(_ candidateYear: Int?, _ year: Int?) -> Int {
        guard let candidateYear, let year else { return Int.max }
        return abs(candidateYear - year)
    }
}
