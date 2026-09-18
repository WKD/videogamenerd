import Foundation

// Value types the ranking UI (Duel/Triage and Tier Board/The Top lanes) consumes.
// Plain `Sendable`/`Hashable` structs — Foundation only, no GRDB/SwiftUI. Produced
// by `RankingStore` observations / one-shots. (PLAN §7, §8.)

// MARK: - Tier Board

/// One row of the Tier Board (PLAN §7): a tier plus its games. `placed` are the
/// fine-ranked games in order (best → worst); `unplaced` is the dimmed tail of
/// games that carry the tier but have no fine-rank key yet (queued for duels).
struct TierBoardRow: Hashable, Sendable, Identifiable {
    var tier: TierInfo
    var placed: [GameSummary]
    var unplaced: [GameSummary]

    var id: Int64 { tier.id }
    var total: Int { placed.count + unplaced.count }
    var isEmpty: Bool { placed.isEmpty && unplaced.isEmpty }

    init(tier: TierInfo, placed: [GameSummary] = [], unplaced: [GameSummary] = []) {
        self.tier = tier
        self.placed = placed
        self.unplaced = unplaced
    }
}

// MARK: - The Top

/// One numbered row of The Top (PLAN §7). The list is ordered by tier then fine
/// rank, so a change of `tierID` between consecutive rows marks a tier divider.
///
/// - `globalPosition` is the rank across **all** placed games, 1…N (nil = the
///   game is unplaced and shown unnumbered at the end of its tier).
/// - `derivedPosition` is the rank **within the current filter's subset**, 1…k —
///   this is what gives "Top PS2 #1, #2 …" while `globalPosition` still shows the
///   true overall standing.
struct TopRow: Hashable, Sendable, Identifiable {
    var game: GameSummary
    var globalPosition: Int?
    var derivedPosition: Int?

    var id: Int64 { game.id }
    var isPlaced: Bool { globalPosition != nil }
    var tierID: Int64? { game.tierID }
    var tierLetter: String? { game.tierLetter }
    var tierColorHex: String? { game.tierColorHex }

    init(game: GameSummary, globalPosition: Int?, derivedPosition: Int?) {
        self.game = game
        self.globalPosition = globalPosition
        self.derivedPosition = derivedPosition
    }
}

// MARK: - Duel

/// What the Duel view should show next (PLAN §7). Either a **placement** duel
/// (placing `candidate` into its tier, dueling `opponent`), a within-tier
/// **refine** duel, or a **border** duel between the bottom of one tier and the
/// top of the next.
struct DuelPrompt: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Codable {
        case placement
        case refine
        case border
    }

    var kind: Kind
    /// The game being placed (placement) or the currently-higher game (refine/border).
    var candidate: Int64
    /// The game to compare it against.
    var opponent: Int64
    var candidateTier: Int64
    var opponentTier: Int64
    /// Placement progress: comparisons answered so far this placement (0-based;
    /// the UI shows `comparisonsMade + 1` of `estimatedTotal`, e.g. "3 of ~6").
    /// Always 0 for refine/border prompts.
    var comparisonsMade: Int
    /// Upper bound on the comparisons the whole placement needs (⌈log₂(n+1)⌉).
    /// 0 for refine/border prompts.
    var estimatedTotal: Int

    /// True for a cross-tier border duel (`candidateTier` above `opponentTier`).
    var isBorder: Bool { kind == .border }
}

/// The result of answering a duel (PLAN §7). A **border** answer never moves a
/// game on its own: it yields a `BorderSuggestion` the UI can accept (→ a move)
/// or dismiss.
enum DuelOutcome: Sendable, Equatable {
    /// A placement duel was answered; `complete` is true once the game landed.
    case placed(gameID: Int64, complete: Bool)
    /// A within-tier refine duel resolved; `swapped` if the two neighbours swapped.
    case refined(swapped: Bool)
    /// A border duel produced a promote/demote suggestion (nil = order confirmed).
    case border(BorderSuggestion?)
    /// There was no active duel to answer.
    case none
}

// MARK: - Stats

/// Placed / unplaced counts per tier (PLAN §7 — cheap ranking stats). Tiers are
/// ordered best → worst.
struct RankingStats: Hashable, Sendable {
    struct TierStat: Hashable, Sendable, Identifiable {
        var tierID: Int64
        var letter: String
        var placed: Int
        var unplaced: Int
        var id: Int64 { tierID }
        var total: Int { placed + unplaced }
    }

    var perTier: [TierStat]

    var totalPlaced: Int { perTier.reduce(0) { $0 + $1.placed } }
    var totalUnplaced: Int { perTier.reduce(0) { $0 + $1.unplaced } }

    init(perTier: [TierStat]) { self.perTier = perTier }
}
