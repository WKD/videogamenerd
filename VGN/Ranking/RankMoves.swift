import Foundation

/// Direct overrides that bypass duels: drag-reorder, cross-tier moves, clearing,
/// re-placing and un-playing. Every function is pure and returns `[RankMutation]`.
enum RankMoves {

    // MARK: - Reorder within a tier

    /// Move the game at `from` to `to` inside one tier (drag-reorder). Assigns the
    /// moved game a key between its new neighbours, or renumbers the tier if no
    /// integer gap remains. `from`/`to` are indices into the tier's placed order.
    static func moveWithinTier(_ slice: TierSlice, from: Int, to: Int) -> [RankMutation] {
        var ids = slice.orderedIDs
        guard ids.indices.contains(from), to >= 0, to < ids.count else { return [] }
        if from == to { return [] }
        let moved = ids.remove(at: from)
        ids.insert(moved, at: to)
        let keyByID = Dictionary(uniqueKeysWithValues: slice.placed.map { ($0.id, $0.key) })
        return assignKey(tier: slice.tier, orderedIDs: ids, keyByID: keyByID, movedID: moved)
    }

    // MARK: - Move across tiers at an exact position

    /// Move `id` into `target` at `insertIndex` (drag between tier rows at a precise
    /// slot). Sets tier and key together; renumbers the target tier when needed.
    static func moveAcrossTiers(_ id: GameID, into target: TierSlice, insertIndex: Int) -> [RankMutation] {
        let existing = target.placed.filter { $0.id != id }
        let index = max(0, min(insertIndex, existing.count))
        switch RankKeySpace.placement(inserting: index, into: existing.map(\.key)) {
        case .key(let k):
            return [.setTier(id: id, tier: target.tier, key: k)]
        case .renumber(let newKeys):
            var ids = existing.map(\.id)
            ids.insert(id, at: index)
            let items = zip(ids, newKeys).map { RankedItem(id: $0.0, key: $0.1) }
            return [.setTier(id: id, tier: target.tier, key: nil), .renumber(tier: target.tier, items: items)]
        }
    }

    // MARK: - Tier changes without a position

    /// Set a game's tier with no position: it drops to the unplaced tail (key
    /// cleared) and is queued for duels.
    static func setTierUnplaced(_ id: GameID, tier: TierID) -> [RankMutation] {
        [.setTier(id: id, tier: tier, key: nil)]
    }

    /// Clear a game's tier entirely (the `0` key): no tier, no rank.
    static func clearTier(_ id: GameID) -> [RankMutation] {
        [.setTier(id: id, tier: nil, key: nil)]
    }

    /// "Re-place": keep the tier, drop the key, re-queue for duels.
    static func rePlace(_ id: GameID) -> [RankMutation] {
        [.clearKey(id: id)]
    }

    /// Un-play a game (played = false): tier and rank must both drop (PLAN §4
    /// invariant 2). Same shape as clearing the tier.
    static func unplay(_ id: GameID) -> [RankMutation] {
        [.setTier(id: id, tier: nil, key: nil)]
    }

    // MARK: - Shared key assignment

    /// Assign a key to `movedID` given the desired `orderedIDs` and the existing
    /// keys of the *other* (unchanged) items. Emits a single `setKey`, or a
    /// `renumber` of the whole tier when no integer gap fits.
    static func assignKey(
        tier: TierID,
        orderedIDs: [GameID],
        keyByID: [GameID: RankKey],
        movedID: GameID
    ) -> [RankMutation] {
        guard let i = orderedIDs.firstIndex(of: movedID) else { return [] }
        let leftKey = i > 0 ? keyByID[orderedIDs[i - 1]] : nil
        let rightKey = i < orderedIDs.count - 1 ? keyByID[orderedIDs[i + 1]] : nil

        let chosen: RankKey?
        switch (leftKey, rightKey) {
        case (nil, nil):
            chosen = RankKeySpace.initial
        case (nil, .some(let r)):
            chosen = RankKeySpace.before(r)
        case (.some(let l), nil):
            chosen = RankKeySpace.after(l)
        case (.some(let l), .some(let r)):
            chosen = RankKeySpace.between(l, r)
        }

        if let key = chosen {
            return [.setKey(id: movedID, key: key)]
        }
        // No gap → renumber the whole tier evenly, preserving the target order.
        let keys = RankKeySpace.renumberKeys(count: orderedIDs.count)
        let items = zip(orderedIDs, keys).map { RankedItem(id: $0.0, key: $0.1) }
        return [.renumber(tier: tier, items: items)]
    }
}
