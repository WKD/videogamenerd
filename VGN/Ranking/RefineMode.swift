import Foundation

/// A neighbour pair proposed for a refine duel.
struct RefinePair: Equatable, Sendable, Codable {
    /// Where the two games sit relative to each other.
    enum Context: Equatable, Sendable, Codable {
        /// Two consecutive games inside one tier. `upper` currently ranks above `lower`.
        case withinTier(TierID)
        /// A border duel: `upper` is the bottom of the higher tier, `lower` the top
        /// of the tier below. The outcome is only a *suggestion*.
        case border(upper: TierID, lower: TierID)
    }
    /// The game currently ranked higher.
    var upper: GameID
    /// The game currently ranked lower.
    var lower: GameID
    var context: Context
}

/// A promote/demote suggestion produced by a border duel. Never applied
/// automatically — the UI surfaces it for the user to accept.
struct BorderSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case promote, demote }
    var game: GameID
    var fromTier: TierID
    var toTier: TierID
    var kind: Kind
}

/// The result of resolving a refine duel.
enum RefineOutcome: Equatable, Sendable {
    /// A within-tier upset: the lower game won and the two should swap.
    case reorder([RankMutation])
    /// A border upset: a suggestion to surface (not a mutation).
    case suggestion(BorderSuggestion)
    /// The existing order was confirmed; nothing to do.
    case noChange
}

/// Chooses which neighbour pairs to compare, prioritising never-compared pairs,
/// then the least-recently-compared, using the comparison log. Resolves a duel
/// into mutations (within-tier swap) or a suggestion (border).
enum RefineMode {

    /// All candidate neighbour pairs (within-tier adjacencies + tier borders),
    /// ordered by refine priority: never-compared first, then oldest comparison
    /// first. Deterministic tie-breaks keep the order stable.
    static func pairs(_ snapshot: RankSnapshot, log: [Comparison]) -> [RefinePair] {
        let tiers = snapshot.orderedTiers
        var candidates: [RefinePair] = []

        // Within-tier adjacent pairs.
        for slice in tiers where slice.placed.count >= 2 {
            for i in 0..<(slice.placed.count - 1) {
                candidates.append(RefinePair(
                    upper: slice.placed[i].id,
                    lower: slice.placed[i + 1].id,
                    context: .withinTier(slice.tier)
                ))
            }
        }
        // Border pairs between consecutive non-empty tiers.
        for i in 0..<max(0, tiers.count - 1) {
            let upperTier = tiers[i]
            let lowerTier = tiers[i + 1]
            guard let bottom = upperTier.placed.last, let top = lowerTier.placed.first else { continue }
            candidates.append(RefinePair(
                upper: bottom.id,
                lower: top.id,
                context: .border(upper: upperTier.tier, lower: lowerTier.tier)
            ))
        }

        let latest = log.latestPerPair()
        // Stable ordering context weight (within before border on ties).
        func contextRank(_ c: RefinePair.Context) -> Int {
            switch c { case .withinTier: return 0; case .border: return 1 }
        }
        return candidates.sorted { lhs, rhs in
            let lDate = latest[PairKey(lhs.upper, lhs.lower)]?.date
            let rDate = latest[PairKey(rhs.upper, rhs.lower)]?.date
            // Never-compared (nil) sort before compared.
            switch (lDate, rDate) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (l?, r?) where l != r: return l < r   // oldest first
            default: break
            }
            // Deterministic tie-breaks.
            if contextRank(lhs.context) != contextRank(rhs.context) {
                return contextRank(lhs.context) < contextRank(rhs.context)
            }
            if lhs.upper != rhs.upper { return lhs.upper < rhs.upper }
            return lhs.lower < rhs.lower
        }
    }

    /// The single next refine pair, or `nil` if there is nothing to refine.
    static func next(_ snapshot: RankSnapshot, log: [Comparison]) -> RefinePair? {
        pairs(snapshot, log: log).first
    }

    /// Resolve a refine duel. `winner` must be one of the pair's two games.
    ///
    /// - Within a tier: if the lower game won, swap the two (as mutations); if the
    ///   upper won, nothing changes.
    /// - Border: any result is a *suggestion*, never an automatic move.
    static func resolve(_ pair: RefinePair, winner: GameID, in snapshot: RankSnapshot) -> RefineOutcome {
        guard winner == pair.upper || winner == pair.lower else { return .noChange }

        switch pair.context {
        case .withinTier(let tier):
            guard winner == pair.lower else { return .noChange } // upper confirmed
            guard let slice = snapshot.slice(for: tier),
                  let iUpper = slice.placed.firstIndex(where: { $0.id == pair.upper }),
                  let iLower = slice.placed.firstIndex(where: { $0.id == pair.lower })
            else { return .noChange }
            // Swap their keys so the lower game rises above the upper. They are
            // adjacent in the refine flow, but swapping keys is correct for any
            // relative position.
            let keyUpper = slice.placed[iUpper].key
            let keyLower = slice.placed[iLower].key
            return .reorder([
                .setKey(id: pair.upper, key: keyLower),
                .setKey(id: pair.lower, key: keyUpper),
            ])

        case .border(let upperTier, let lowerTier):
            if winner == pair.lower {
                // Top of the lower tier beat the bottom of the higher tier → promote it.
                return .suggestion(BorderSuggestion(
                    game: pair.lower, fromTier: lowerTier, toTier: upperTier, kind: .promote
                ))
            } else {
                // Bottom of the higher tier confirmed above the lower tier's top →
                // no change is forced, but we can suggest demoting the borderline
                // higher-tier game only if the user asked; default is no change.
                return .noChange
            }
        }
    }
}
