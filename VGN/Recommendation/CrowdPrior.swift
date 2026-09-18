import Foundation

/// The crowd prior (PLAN §7b): IGDB's aggregated rating, weighted by its rating
/// count, whose influence **shrinks as the user's ranked count grows** — dominant
/// with ~10 ranked games, a tie-breaker with 200. Pure; independently testable.
enum CrowdPrior {

    /// The crowd's 0…1 score for a candidate (rating/100), or `nil` when unrated.
    static func score(rating: Double?) -> Double? {
        guard let rating else { return nil }
        return min(max(rating / 100.0, 0), 1)
    }

    /// The weight the crowd prior carries in the blend for a candidate. Combines a
    /// base ceiling, decay in the ranked count, and rating-count confidence. `0`
    /// when the candidate is unrated.
    static func weight(
        rating: Double?, ratingCount: Int?, rankedCount: Int, weights: RecommendationWeights
    ) -> Double {
        guard rating != nil else { return 0 }
        let decay = weights.crowdRankedHalfLife
            / (weights.crowdRankedHalfLife + Double(max(0, rankedCount)))
        let count = Double(max(0, ratingCount ?? 0))
        let confidence = count / (count + weights.crowdCountConfidence)
        return weights.crowdBaseWeight * decay * confidence
    }
}
