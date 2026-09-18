import Foundation

/// The algebra of sparse `Int64` rank keys.
///
/// Keys live on a wide integer axis with a large default `step` between adjacent
/// games, so an insertion is almost always the plain integer midpoint of its two
/// neighbours. When two neighbours become adjacent integers (no midpoint exists),
/// the caller renumbers the tier evenly — cheap and rare at this scale.
///
/// All operations are total and overflow-safe; when an operation cannot produce a
/// key that preserves strict ordering it returns `nil`, signalling "renumber".
enum RankKeySpace {
    /// Default gap between adjacent keys. 2^32 leaves ~2 billion append steps and
    /// 32 levels of midpoint subdivision before a renumber is forced.
    static let step: RankKey = 1 << 32

    /// The key for the first game in an empty tier. Centred so both prepend and
    /// append have room without immediately renumbering.
    static let initial: RankKey = 1 << 62

    /// Append after the current last key (`last + step`), or `nil` on overflow.
    static func after(_ last: RankKey) -> RankKey? {
        let (sum, overflow) = last.addingReportingOverflow(step)
        return overflow ? nil : sum
    }

    /// Prepend before the current first key (`first - step`), or `nil` on underflow.
    static func before(_ first: RankKey) -> RankKey? {
        let (diff, overflow) = first.subtractingReportingOverflow(step)
        return overflow ? nil : diff
    }

    /// The integer strictly between `low` and `high`, or `nil` when none exists
    /// (adjacent, equal or out-of-order). Fully overflow-safe: uses the bitwise
    /// floor-average `(a & b) + ((a ^ b) >> 1)`, which never overflows even for
    /// `.min`/`.max`.
    static func between(_ low: RankKey, _ high: RankKey) -> RankKey? {
        guard low < high else { return nil }
        let mid = (low & high) + ((low ^ high) >> 1)
        return (mid > low && mid < high) ? mid : nil
    }

    /// Evenly spaced keys for `count` items, centred around `initial`, each a
    /// multiple of `step`. Used to renumber a whole tier.
    static func renumberKeys(count: Int) -> [RankKey] {
        guard count > 0 else { return [] }
        // Start at `step` and go up by `step`; this keeps keys positive and small,
        // easy to read while debugging, with prepend room below.
        return (1...count).map { RankKey($0) * step }
    }

    // MARK: - High-level placement

    /// The outcome of choosing a key for an item inserted at `index` into a tier
    /// whose existing placed items have `keys` (ascending). Either a single key
    /// fits between the neighbours, or the tier must be renumbered.
    enum Placement: Equatable {
        /// A concrete key fits; assign it with a `setKey`.
        case key(RankKey)
        /// No integer gap; renumber. `keys` are the new evenly spaced keys for the
        /// FULL post-insertion ordering (existing items with the new item spliced
        /// in at `index`).
        case renumber([RankKey])
    }

    /// Choose a key to insert a new item at `index` (0…keys.count) into `keys`.
    static func placement(inserting index: Int, into keys: [RankKey]) -> Placement {
        precondition(index >= 0 && index <= keys.count, "insertion index out of range")
        if keys.isEmpty { return .key(initial) }
        if index == 0 {
            if let k = before(keys[0]) { return .key(k) }
            return .renumber(renumberKeys(count: keys.count + 1))
        }
        if index == keys.count {
            if let k = after(keys[keys.count - 1]) { return .key(k) }
            return .renumber(renumberKeys(count: keys.count + 1))
        }
        if let k = between(keys[index - 1], keys[index]) { return .key(k) }
        return .renumber(renumberKeys(count: keys.count + 1))
    }

    /// Whether a tier's keys are so tightly packed that a renumber is advisable
    /// even before the next insertion (any adjacent pair with no gap, or a
    /// non-increasing pair). Used by the invariant checker / maintenance.
    static func needsRenumber(_ keys: [RankKey]) -> Bool {
        guard keys.count >= 2 else { return false }
        for i in 1..<keys.count {
            if keys[i] <= keys[i - 1] { return true } // duplicate or disordered
            let (gap, overflow) = keys[i].subtractingReportingOverflow(keys[i - 1])
            if !overflow, gap < 2 { return true }     // adjacent integers
        }
        return false
    }
}
