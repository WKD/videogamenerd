import Foundation

/// A `(kind, value)` taste feature key.
struct TraitKey: Hashable, Sendable {
    var kind: GameTraitKind
    var value: String
    init(_ kind: GameTraitKind, _ value: String) { self.kind = kind; self.value = value }
    init(_ trait: GameTrait) { self.kind = trait.kind; self.value = trait.value }
}

/// Score-from-rank (PLAN §7b): turn a ``RankSnapshot`` into a 0…1 taste score per
/// tiered game — placed games by global percentile, tiered-but-unplaced games at
/// their tier's midpoint. Pure; independently testable.
enum TasteScoring {

    /// 0…1 score for every tiered game (played + tiered). #1 overall ≈ 1, last ≈ 0.
    /// Unplaced games in a tier take that tier's midpoint score; a tier with no
    /// placed games is scored from its band among the tiers.
    static func rankScores(snapshot: RankSnapshot) -> [GameID: Double] {
        let chart = GlobalRank.chart(snapshot)
        let n = chart.count
        var scores: [GameID: Double] = [:]

        // Placed games: percentile by global position (1-based).
        func percentile(position: Int) -> Double {
            guard n > 0 else { return 0.5 }
            return (Double(n - position) + 0.5) / Double(n)
        }
        for row in chart { scores[row.id] = percentile(position: row.position) }

        // Per-tier midpoint over the placed band.
        var placedPositions: [TierID: [Int]] = [:]
        for row in chart { placedPositions[row.tier, default: []].append(row.position) }

        let tiers = snapshot.orderedTiers
        let tierCount = max(1, tiers.count)
        for (index, slice) in tiers.enumerated() {
            guard !slice.unplaced.isEmpty else { continue }
            let midpoint: Double
            if let positions = placedPositions[slice.tier], !positions.isEmpty {
                let mid = Double(positions.min()! + positions.max()!) / 2
                midpoint = percentile(position: Int(mid.rounded()))
            } else {
                // Empty tier: band by sort order among the tiers (S high … F low).
                midpoint = (Double(tierCount - index) - 0.5) / Double(tierCount)
            }
            for id in slice.unplaced { scores[id] = midpoint }
        }
        return scores
    }
}

// MARK: - Trait affinity profile (shrunk Bayesian averages)

/// The user's per-trait taste, learned from ranked games (PLAN §7b trait
/// affinities). Each trait's mean score is shrunk toward the overall mean by a
/// prior of strength `K`, so thin evidence stays near-neutral and negative
/// evidence counts.
struct TraitProfile: Sendable {
    /// Overall mean of ranked scores (≈ 0.5 for a full library).
    let mean: Double
    let rankedCount: Int
    /// Per trait: shrunk affinity and the sample count behind it.
    let affinities: [TraitKey: (shrunk: Double, n: Int)]
    private let priorStrength: Double

    init(ranked: [RankedGame], weights: RecommendationWeights) {
        self.priorStrength = weights.traitPriorStrength
        self.rankedCount = ranked.count
        let overall = ranked.isEmpty ? 0.5 : ranked.map(\.score).reduce(0, +) / Double(ranked.count)
        self.mean = overall

        var sums: [TraitKey: (sum: Double, n: Int)] = [:]
        for game in ranked {
            // A game contributes to each distinct trait key once.
            var seen: Set<TraitKey> = []
            for trait in game.traits {
                let key = TraitKey(trait)
                guard seen.insert(key).inserted else { continue }
                var entry = sums[key] ?? (0, 0)
                entry.sum += game.score
                entry.n += 1
                sums[key] = entry
            }
        }
        var out: [TraitKey: (shrunk: Double, n: Int)] = [:]
        for (key, entry) in sums {
            let rawMean = entry.sum / Double(entry.n)
            let shrunk = (Double(entry.n) * rawMean + priorStrength * overall)
                / (Double(entry.n) + priorStrength)
            out[key] = (shrunk, entry.n)
        }
        self.affinities = out
    }

    /// A trait's confidence weight `n / (n + K)` — 0 for an unseen trait.
    func confidence(_ key: TraitKey) -> Double {
        guard let entry = affinities[key] else { return 0 }
        return Double(entry.n) / (Double(entry.n) + priorStrength)
    }

    /// A trait's signed lift (shrunk affinity − mean); 0 for an unseen trait.
    func lift(_ key: TraitKey) -> Double {
        guard let entry = affinities[key] else { return 0 }
        return entry.shrunk - mean
    }

    /// One trait's contribution to a candidate.
    struct Contribution: Sendable {
        var key: TraitKey
        var lift: Double
        var confidence: Double
        /// `confidence · lift` — the actual push on the score.
        var weighted: Double { confidence * lift }
    }

    /// A candidate's affinity = its traits' confidence-weighted mean lift, plus the
    /// per-trait contributions (for reasons) and the summed confidence (evidence).
    func affinity(for traits: [GameTrait]) -> (deviation: Double, evidence: Double, contributions: [Contribution]) {
        var contributions: [Contribution] = []
        var seen: Set<TraitKey> = []
        var weightedSum = 0.0
        var confidenceSum = 0.0
        for trait in traits {
            let key = TraitKey(trait)
            guard seen.insert(key).inserted else { continue }
            let c = confidence(key)
            guard c > 0 else { continue }
            let l = lift(key)
            contributions.append(Contribution(key: key, lift: l, confidence: c))
            weightedSum += c * l
            confidenceSum += c
        }
        let deviation = confidenceSum > 0 ? weightedSum / confidenceSum : 0
        return (deviation, confidenceSum, contributions)
    }
}
