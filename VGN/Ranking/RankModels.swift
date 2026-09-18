import Foundation

// MARK: - Identifiers

/// Row id for a game. Mirrors the DB `games.id` column.
typealias GameID = Int64

/// Row id for a tier. Mirrors the DB `tiers.id` column.
typealias TierID = Int64

// NOTE ON `RankKey`
// -----------------
// The sparse, SQL-sortable rank key type is `RankKey = Int64`. That typealias is
// defined ONCE for the whole app in `VGN/Model/RankKey.swift` (Agent A's lane), so
// it is deliberately NOT declared here to avoid a duplicate-symbol collision at
// merge. The DB column `games.rank_key` is a nullable `INTEGER` (SQLite: signed
// 64-bit). Ordering a tier is a plain `ORDER BY rank_key`. Insertion between two
// neighbours is their integer midpoint; when no integer fits, the engine emits a
// `renumber` of the whole tier in the same mutation batch. Sparse integers beat
// string fractional indexing here: trivially debuggable, index-friendly, no custom
// collation, and renumbering is free and rare at a personal-library scale.
// The key algebra lives in `enum RankKeySpace` (see RankKeySpace.swift).

// MARK: - Snapshots (engine input)

/// One ordered entry inside a tier: a game with its concrete rank key.
struct RankedItem: Hashable, Sendable, Codable {
    var id: GameID
    var key: RankKey

    init(id: GameID, key: RankKey) {
        self.id = id
        self.key = key
    }
}

/// A contiguous slice of the global order: one tier's placed games (ordered by
/// key ascending — index 0 is the best) plus its *unplaced* games (games that
/// carry this tier but have no key yet, queued for duels).
struct TierSlice: Sendable, Codable, Equatable {
    var tier: TierID
    /// Tier ordering: lower sorts higher in the global chart (S = 0 … F = 5).
    var sort: Int
    /// Placed games, ordered by key ascending. Invariant: strictly increasing keys.
    var placed: [RankedItem]
    /// Games with this tier but no key yet. Deterministic order = queue order.
    var unplaced: [GameID]

    init(tier: TierID, sort: Int, placed: [RankedItem] = [], unplaced: [GameID] = []) {
        self.tier = tier
        self.sort = sort
        self.placed = placed
        self.unplaced = unplaced
    }

    var orderedIDs: [GameID] { placed.map(\.id) }
}

/// The whole played-games ranking as plain values. The engine reads this and
/// returns mutations; it never mutates a snapshot in place.
struct RankSnapshot: Sendable, Codable, Equatable {
    /// Tiers in global order (sorted by `sort`). The engine tolerates any input
    /// order and sorts defensively where it matters.
    var tiers: [TierSlice]

    init(tiers: [TierSlice]) {
        self.tiers = tiers
    }

    /// Tiers sorted by `sort` then `tier` id (deterministic tie-break).
    var orderedTiers: [TierSlice] {
        tiers.sorted { $0.sort != $1.sort ? $0.sort < $1.sort : $0.tier < $1.tier }
    }

    func slice(for tier: TierID) -> TierSlice? {
        tiers.first { $0.tier == tier }
    }
}

// MARK: - Mutations (engine output)

/// A single change the DB lane will apply inside one transaction. The engine
/// returns these as *values*; it performs no I/O.
enum RankMutation: Equatable, Sendable, Codable {
    /// Give a game a concrete rank key within its current tier.
    case setKey(id: GameID, key: RankKey)
    /// Move a game to `tier` (nil clears the tier entirely, e.g. un-playing) with
    /// an optional key (nil ⇒ unplaced tail, key cleared).
    case setTier(id: GameID, tier: TierID?, key: RankKey?)
    /// Clear a game's key but keep its tier — it drops to the unplaced tail and
    /// is re-queued for duels ("re-place").
    case clearKey(id: GameID)
    /// Re-space an entire tier evenly. `items` is the full ordered membership
    /// with freshly assigned keys. Emitted when integer gaps run out.
    case renumber(tier: TierID, items: [RankedItem])
}

// MARK: - Comparison log

/// One recorded duel. Never deleted; the log powers refine ordering, contradiction
/// detection and history.
struct Comparison: Hashable, Sendable, Codable {
    enum Context: String, Sendable, Codable {
        case placement
        case refine
        case border
    }
    var winner: GameID
    var loser: GameID
    /// Seconds since a fixed epoch (or any monotonic value). Latest wins when a
    /// pair is compared more than once.
    var date: Double
    var context: Context

    init(winner: GameID, loser: GameID, date: Double, context: Context) {
        self.winner = winner
        self.loser = loser
        self.date = date
        self.context = context
    }

    /// Unordered key for the pair, smaller id first.
    var pairKey: PairKey { PairKey(winner, loser) }
}

/// An unordered pair of game ids, normalised so `a <= b`.
struct PairKey: Hashable, Sendable, Codable, Comparable {
    var a: GameID
    var b: GameID
    init(_ x: GameID, _ y: GameID) {
        if x <= y { a = x; b = y } else { a = y; b = x }
    }
    static func < (lhs: PairKey, rhs: PairKey) -> Bool {
        lhs.a != rhs.a ? lhs.a < rhs.a : lhs.b < rhs.b
    }
}

extension Array where Element == Comparison {
    /// The latest comparison for each unordered pair (superseded ones dropped).
    /// Deterministic: ties on `date` broken by original array order (later index
    /// wins, matching "latest recorded").
    func latestPerPair() -> [PairKey: Comparison] {
        var out: [PairKey: Comparison] = [:]
        for c in self {
            if let existing = out[c.pairKey] {
                if c.date >= existing.date { out[c.pairKey] = c }
            } else {
                out[c.pairKey] = c
            }
        }
        return out
    }
}
