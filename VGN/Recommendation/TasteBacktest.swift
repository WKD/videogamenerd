import Foundation

/// The leave-one-out self-check (PLAN §7b "It checks itself"): hide each ranked
/// game, predict its taste score from the others with the same affinity + direct
/// link model, and correlate predicted vs actual with Spearman ρ. Pure and fast at
/// personal-library scale; it is how the weights get tuned on a real library.
enum TasteBacktest {

    /// Fewer ranked games than this ⇒ `notEnoughData` (PLAN §7b: "under ~15").
    static let minSamples = 15
    /// ρ at/above this ⇒ `good`.
    static let goodThreshold = 0.45
    /// ρ below `good` but at/above this ⇒ `rough`; below ⇒ `rough` too (a low or
    /// negative correlation is still "rough", not a hard fail).
    static let roughFloor = -1.0

    /// Run the backtest, plus — when `excludingFirstPlayedBefore` is set — the same backtest
    /// over the ranked games **minus** those first played before that year (PLAN §7b: "run
    /// excluding games first played before a chosen year, to show how far nostalgia and
    /// present taste have drifted"). Only games with a known first-played year are removed.
    static func run(
        ranked: [RankedGame], weights: RecommendationWeights = RecommendationWeights(),
        excludingFirstPlayedBefore year: Int?
    ) -> TasteBacktestResult {
        var result = run(ranked: ranked, weights: weights)
        guard let year else { return result }
        let kept = ranked.filter { game in
            guard let first = game.firstPlayedYear else { return true }
            return first >= year
        }
        let filtered = run(ranked: kept, weights: weights)
        result.cutoff = TasteBacktestResult.Cutoff(
            year: year, spearman: filtered.spearman, sampleCount: kept.count,
            excludedCount: ranked.count - kept.count)
        return result
    }

    /// Run the backtest over the ranked games.
    static func run(ranked: [RankedGame], weights: RecommendationWeights = RecommendationWeights()) -> TasteBacktestResult {
        guard ranked.count >= minSamples else {
            return TasteBacktestResult(spearman: nil, sampleCount: ranked.count, verdict: .notEnoughData)
        }

        var predicted: [Double] = []
        var actual: [Double] = []
        predicted.reserveCapacity(ranked.count)
        actual.reserveCapacity(ranked.count)

        for i in ranked.indices {
            let held = ranked[i]
            var others = ranked
            others.remove(at: i)
            predicted.append(predict(held, from: others, weights: weights))
            actual.append(held.score)
        }

        let rho = spearman(predicted, actual)
        let verdict: TasteVerdict
        if let rho, rho >= goodThreshold { verdict = .good } else { verdict = .rough }
        return TasteBacktestResult(spearman: rho, sampleCount: ranked.count, verdict: verdict)
    }

    /// Predict a game's taste score from the other ranked games (affinity + links,
    /// no crowd/time — those aren't taste signals we tune here).
    static func predict(_ game: RankedGame, from others: [RankedGame], weights: RecommendationWeights) -> Double {
        let profile = TraitProfile(ranked: others, weights: weights)
        let affinity = profile.affinity(for: game.traits)
        let pseudo = Candidate(id: game.id, igdbID: game.igdbID, traits: game.traits, status: .backlog)
        let links = DirectLinks.evaluate(candidate: pseudo, ranked: others, weights: weights)
        let signal = weights.traitAffinityWeight * affinity.deviation + links.score
        return min(max(profile.mean + signal, 0), 1)
    }

    // MARK: - Spearman

    /// Spearman rank correlation ρ, `nil` when it is undefined (constant input).
    static func spearman(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        return pearson(ranks(a), ranks(b))
    }

    /// Fractional ranks (ties get the average rank).
    static func ranks(_ values: [Double]) -> [Double] {
        let sorted = values.enumerated().sorted { $0.element < $1.element }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].element == sorted[i].element { j += 1 }
            let rank = Double(i + j) / 2 + 1     // average rank (1-based) for the tie block
            for k in i...j { result[sorted[k].offset] = rank }
            i = j + 1
        }
        return result
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var cov = 0.0, varA = 0.0, varB = 0.0
        for i in a.indices {
            let da = a[i] - meanA, db = b[i] - meanB
            cov += da * db; varA += da * da; varB += db * db
        }
        guard varA > 0, varB > 0 else { return nil }
        return cov / (varA.squareRoot() * varB.squareRoot())
    }
}
