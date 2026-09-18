import Foundation

/// Decides what to duel next: unplaced games first (deterministic order), then
/// refine pairs. Pure over a snapshot + comparison log.
enum RankQueue {

    /// A unit of work for the Duel view.
    enum Item: Equatable, Sendable {
        /// Run a placement session for this unplaced game in its tier.
        case place(game: GameID, tier: TierID)
        /// Run a single refine duel.
        case refine(RefinePair)
    }

    /// Every unplaced game, ordered by tier sort then the tier's queue order.
    static func placements(_ snapshot: RankSnapshot) -> [(game: GameID, tier: TierID)] {
        var out: [(GameID, TierID)] = []
        for slice in snapshot.orderedTiers {
            for id in slice.unplaced {
                out.append((id, slice.tier))
            }
        }
        return out
    }

    /// The next thing to duel: an unplaced placement if any remain, otherwise the
    /// top-priority refine pair, otherwise `nil`.
    static func next(_ snapshot: RankSnapshot, log: [Comparison]) -> Item? {
        if let first = placements(snapshot).first {
            return .place(game: first.game, tier: first.tier)
        }
        if let pair = RefineMode.next(snapshot, log: log) {
            return .refine(pair)
        }
        return nil
    }

    /// Count of games still awaiting an initial placement (sidebar "Duel" badge).
    static func unplacedCount(_ snapshot: RankSnapshot) -> Int {
        snapshot.tiers.reduce(0) { $0 + $1.unplaced.count }
    }
}
