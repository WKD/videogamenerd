import Foundation

/// Time fit (PLAN §7b step 1): keep candidates whose estimate fits the bracket,
/// with a smooth falloff just outside it and a hard exclusion beyond ~1.5× the
/// upper bound. Pure; independently testable.
enum TimeFit {

    struct Result: Hashable, Sendable {
        /// 0…1 how well the estimate fits (1 = squarely inside the bracket).
        var fit: Double
        /// True when the estimate is beyond the hard limit — drop the candidate.
        var excluded: Bool
    }

    /// Evaluate an estimate (already remaining-adjusted for a `playing` game)
    /// against a bracket.
    static func evaluate(
        estimateSeconds estimate: Int, bracket: TimeBracket, weights: RecommendationWeights
    ) -> Result {
        let lower = bracket.lowerSeconds ?? 0
        let e = max(0, estimate)

        // Below the lower bound: still eligible, gentle falloff to the short floor.
        func belowLowerFit() -> Double {
            guard lower > 0 else { return 1 }               // no lower bound (e.g. an evening)
            let ratio = min(1, Double(e) / Double(lower))
            return weights.timeShortFloor + (1 - weights.timeShortFloor) * ratio
        }

        guard let upper = bracket.upperSeconds else {
            // Unbounded upper ("a long haul"): never excluded; only a lower falloff.
            return Result(fit: e >= lower ? 1 : belowLowerFit(), excluded: false)
        }

        let hardLimit = Double(upper) * weights.timeHardMultiplier
        if Double(e) > hardLimit { return Result(fit: 0, excluded: true) }
        if e < lower { return Result(fit: belowLowerFit(), excluded: false) }
        if e <= upper { return Result(fit: 1, excluded: false) }
        // Between upper and the hard limit: linear falloff 1 → 0.
        let span = hardLimit - Double(upper)
        let over = Double(e) - Double(upper)
        let fit = span > 0 ? max(0, 1 - over / span) : 0
        return Result(fit: fit, excluded: false)
    }
}
