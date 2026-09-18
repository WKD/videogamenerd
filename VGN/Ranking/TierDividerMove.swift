import Foundation

/// Moving the boundary between two adjacent tiers (PLAN §7 extension — "tiers are
/// slices of one ordered list, so a boundary is a position that can be dragged").
/// Pure — Foundation only; returns `[RankMutation]` for the store to apply.
///
/// `k > 0` (downward): the top `k` **placed** games of the lower tier become the
/// bottom `k` of the upper tier, order untouched. `k < 0` (upward): the bottom
/// `|k|` placed games of the upper tier become the top `|k|` of the lower tier.
/// `k` is clamped to what exists; only placed games move (unplaced tails stay with
/// their tier); `k == 0` is a no-op.
enum TierDividerMove {

    /// The games that changed tier (for the store's outcome / undo capture).
    static func movedIDs(snapshot: RankSnapshot, upperTier: TierID, lowerTier: TierID, by k: Int) -> [GameID] {
        guard k != 0, let upper = snapshot.slice(for: upperTier), let lower = snapshot.slice(for: lowerTier)
        else { return [] }
        if k > 0 {
            return Array(lower.placed.prefix(min(k, lower.placed.count))).map(\.id)
        } else {
            return Array(upper.placed.suffix(min(-k, upper.placed.count))).map(\.id)
        }
    }

    static func mutations(snapshot: RankSnapshot, upperTier: TierID, lowerTier: TierID, by k: Int) -> [RankMutation] {
        guard k != 0,
              let upper = snapshot.slice(for: upperTier),
              let lower = snapshot.slice(for: lowerTier) else { return [] }

        let upperIDs = upper.placed.map(\.id)
        let lowerIDs = lower.placed.map(\.id)
        var newUpper: [GameID]
        var newLower: [GameID]
        var movedToUpper: [GameID] = []
        var movedToLower: [GameID] = []

        if k > 0 {
            let kk = min(k, lowerIDs.count)
            guard kk > 0 else { return [] }
            movedToUpper = Array(lowerIDs.prefix(kk))
            newUpper = upperIDs + movedToUpper
            newLower = Array(lowerIDs.dropFirst(kk))
        } else {
            let kk = min(-k, upperIDs.count)
            guard kk > 0 else { return [] }
            movedToLower = Array(upperIDs.suffix(kk))
            newUpper = Array(upperIDs.dropLast(kk))
            newLower = movedToLower + lowerIDs
        }

        var mutations: [RankMutation] = []
        // Re-tier the crossing games first (key cleared), then renumber both tiers
        // so every placed game gets a fresh, strictly-increasing key. Unplaced
        // tails are not listed, so they keep their tier and their null keys.
        for id in movedToUpper { mutations.append(.setTier(id: id, tier: upperTier, key: nil)) }
        for id in movedToLower { mutations.append(.setTier(id: id, tier: lowerTier, key: nil)) }
        mutations += renumber(tier: upperTier, ids: newUpper)
        mutations += renumber(tier: lowerTier, ids: newLower)
        return mutations
    }

    private static func renumber(tier: TierID, ids: [GameID]) -> [RankMutation] {
        guard !ids.isEmpty else { return [] }
        let keys = RankKeySpace.renumberKeys(count: ids.count)
        return [.renumber(tier: tier, items: zip(ids, keys).map { RankedItem(id: $0.0, key: $0.1) })]
    }
}
