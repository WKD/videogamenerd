import Foundation

/// The strongest, most legible signal at small scale (PLAN §7b "Direct links"):
/// same franchise / series / developer as a ranked game, or an IGDB
/// `similar_games` connection to one. A link to a highly-ranked game pushes a
/// candidate up; a link to a D–F game subtracts. Pure; independently testable.
///
/// A ``DirectLinks/Index`` is built once per recommendation (O(ranked)) so scoring
/// each candidate is O(candidate traits), not O(ranked) — this keeps `recommend`
/// fast on a 2 000-game library.
enum DirectLinks {

    /// A ranked game reduced to what a link needs.
    struct RankedRef: Hashable, Sendable {
        var id: GameID
        var score: Double
    }

    /// Precomputed lookups over the ranked games.
    struct Index: Sendable {
        /// franchise / series / developer value → ranked games carrying it.
        var byValue: [TraitKey: [RankedRef]] = [:]
        /// IGDB id → ranked games that list it in *their* `similar_games`.
        var similarByIGDB: [Int64: [RankedRef]] = [:]
        /// IGDB id → the ranked game with that id (for the reverse direction).
        var rankedByIGDB: [Int64: RankedRef] = [:]

        init(ranked: [RankedGame]) {
            for game in ranked {
                let ref = RankedRef(id: game.id, score: game.score)
                if let igdb = game.igdbID { rankedByIGDB[igdb] = ref }
                for trait in game.traits {
                    switch trait.kind {
                    case .franchise, .series, .developer:
                        byValue[TraitKey(trait), default: []].append(ref)
                    case .similar:
                        if let sid = trait.similarGameID { similarByIGDB[sid, default: []].append(ref) }
                    default: break
                    }
                }
            }
        }
    }

    /// One resolved link between a candidate and a ranked game.
    struct Link: Hashable, Sendable {
        var kind: GameTraitKind
        var value: String
        var exemplar: GameID
        var exemplarScore: Double
        /// Signed, per-kind-weighted push on the candidate's taste score.
        var contribution: Double
    }

    /// Convenience for callers that don't reuse an index (tests).
    static func evaluate(
        candidate: Candidate, ranked: [RankedGame], weights: RecommendationWeights
    ) -> (score: Double, links: [Link]) {
        evaluate(candidate: candidate, index: Index(ranked: ranked), weights: weights)
    }

    static func evaluate(
        candidate: Candidate, index: Index, weights: RecommendationWeights
    ) -> (score: Double, links: [Link]) {
        var links: [Link] = []

        // 1. Value-equality links: franchise / series / developer.
        for kind in [GameTraitKind.franchise, .series, .developer] {
            let weight = kindWeight(kind, weights)
            var handled: Set<String> = []
            for trait in candidate.traits where trait.kind == kind {
                guard handled.insert(trait.value).inserted else { continue }
                guard let sharers = index.byValue[TraitKey(kind, trait.value)], !sharers.isEmpty else { continue }
                let mean = sharers.map(\.score).reduce(0, +) / Double(sharers.count)
                let exemplar = sharers.max { abs($0.score - 0.5) < abs($1.score - 0.5) }!
                links.append(Link(kind: kind, value: trait.value, exemplar: exemplar.id,
                                  exemplarScore: exemplar.score,
                                  contribution: (mean - 0.5) * weight))
            }
        }

        // 2. Similar-games links (IGDB ids, either direction), deduped by exemplar.
        var similarExemplars: Set<GameID> = []
        func addSimilar(_ ref: RankedRef) {
            guard ref.id != candidate.id, similarExemplars.insert(ref.id).inserted else { return }
            links.append(Link(kind: .similar, value: "", exemplar: ref.id,
                              exemplarScore: ref.score,
                              contribution: (ref.score - 0.5) * weights.similarLinkWeight))
        }
        if let cig = candidate.igdbID {
            for ref in index.similarByIGDB[cig] ?? [] { addSimilar(ref) }   // ranked lists candidate
        }
        for sid in candidate.similarIGDBIDs {                               // candidate lists ranked
            if let ref = index.rankedByIGDB[sid] { addSimilar(ref) }
        }

        let raw = links.map(\.contribution).reduce(0, +)
        let capped = min(max(raw, -weights.directLinkCap), weights.directLinkCap)
        return (capped, links)
    }

    private static func kindWeight(_ kind: GameTraitKind, _ weights: RecommendationWeights) -> Double {
        switch kind {
        case .franchise: return weights.franchiseLinkWeight
        case .series: return weights.seriesLinkWeight
        case .developer: return weights.developerLinkWeight
        case .similar: return weights.similarLinkWeight
        default: return 0
        }
    }
}
