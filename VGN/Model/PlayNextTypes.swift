import Foundation

// MARK: - Time commitment bracket

/// The time-commitment bracket the user picks (PLAN §7b Inputs). One of the five
/// "By Length" ``LengthShelf`` shelves (whose hour bounds derive from the owner's
/// weekly ``PlayPace`` — the same source of truth as the sidebar), or a precise
/// custom budget (hours/week × weeks). The `completionist` toggle switches a
/// candidate's estimate from IGDB `normally` to `completely`.
///
/// Foundation-only value; the engine reads `lowerSeconds` / `upperSeconds`. There is
/// **one** source of truth for names + bounds: ``LengthShelf`` and
/// ``LengthShelf/bounds(for:)`` — this type never re-defines them.
struct TimeBracket: Hashable, Sendable, Codable {
    /// The chosen length shelf, or `nil` for a custom budget.
    var shelf: LengthShelf?
    /// The weekly pace that resolves a shelf's hour bounds (shared with the sidebar;
    /// ignored for a custom budget). Changing it re-derives the bounds.
    var pace: PlayPace
    /// The owner's play style, which sets each candidate's **personal length** for the
    /// time fit (owner request 2026-09-19). Shared with the sidebar. The
    /// ``completionist`` flag overrides it to `.completionist` (plan for 100%).
    var playStyle: PlayStyle
    /// Precise mode: a total budget in seconds (upper bound, no lower bound).
    var customBudgetSeconds: Int?
    /// Per-session "plan for 100%" override: estimate to `.completionist` (t = 1)
    /// regardless of the owner's usual play style.
    var completionist: Bool

    init(shelf: LengthShelf, pace: PlayPace = .default,
         playStyle: PlayStyle = .default, completionist: Bool = false) {
        self.shelf = shelf
        self.pace = pace
        self.playStyle = playStyle
        self.customBudgetSeconds = nil
        self.completionist = completionist
    }

    init(budgetSeconds: Int, playStyle: PlayStyle = .default, completionist: Bool = false) {
        self.shelf = nil
        self.pace = .default
        self.playStyle = playStyle
        self.customBudgetSeconds = budgetSeconds
        self.completionist = completionist
    }

    /// The style the time fit actually uses: the "plan for 100%" toggle forces
    /// `.completionist`, otherwise the owner's usual style.
    var resolvedStyle: PlayStyle { completionist ? .completionist : playStyle }

    private static let secondsPerHour = 3600.0

    /// The shelf edges for the current pace (the one source of bounds).
    private var bounds: LengthBounds { LengthShelf.bounds(for: pace) }

    /// Lower bound in seconds (`nil` = no lower bound / anything shorter is fine —
    /// e.g. "One Evening" is open below, and a custom budget has no floor).
    var lowerSeconds: Int? {
        guard let shelf else { return nil }
        return shelf.secondsRange(in: bounds).lower
    }

    /// Upper bound in seconds (`nil` = unbounded above, e.g. "Epics").
    var upperSeconds: Int? {
        if let custom = customBudgetSeconds { return custom }
        return shelf?.secondsRange(in: bounds).upper
    }

    /// A short label for reasons / display / the "Ask Claude" prompt: the shelf name
    /// **with** its current hour range ("One Evening (under 4 h)"), or the budget.
    var label: String {
        if let shelf { return "\(shelf.name) (\(shelf.subtitle(bounds: bounds)))" }
        if let budget = customBudgetSeconds {
            return "~\(Int((Double(budget) / Self.secondsPerHour).rounded())) h budget"
        }
        return "Any length"
    }

    /// Just the hour range for the selected bracket, e.g. "4–10 h", "under 4 h",
    /// "80 h and more", or "≈ 16 h" for a custom budget (the bar's caption).
    var rangeText: String {
        if let shelf { return shelf.subtitle(bounds: bounds) }
        if let budget = customBudgetSeconds {
            return "≈ \(Int((Double(budget) / Self.secondsPerHour).rounded())) h"
        }
        return ""
    }
}

// MARK: - Match strength

/// How much evidence backed a suggestion's score (PLAN §7b "match strength").
enum MatchStrength: String, Hashable, Sendable, Codable, Comparable {
    case weak
    case fair
    case strong

    private var order: Int { switch self { case .weak: 0; case .fair: 1; case .strong: 2 } }
    static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool { lhs.order < rhs.order }

    var label: String { rawValue.capitalized }
}

// MARK: - Reasons

/// A structured reason a game was suggested (PLAN §7b "Explain"). The engine
/// builds these values; the **UI** formats them into sentences — the engine never
/// produces display strings.
enum PlayNextReason: Hashable, Sendable {
    /// Same franchise as a ranked game (the exemplar). `value` is the franchise name.
    case sharedFranchise(value: String, with: GameID)
    /// Same series/collection as a ranked game.
    case sharedSeries(value: String, with: GameID)
    /// Same developer as a top-ranked game.
    case sameDeveloper(name: String, exemplar: GameID)
    /// Listed in (or listing) a top-ranked game's IGDB `similar_games`.
    case similarTo(GameID)
    /// A trait you tend to rank high (or low): `lift` is the shrunk affinity minus
    /// your mean (positive = you like it, negative = you don't).
    case traitAffinity(kind: GameTraitKind, value: String, lift: Double)
    /// The estimate fits the chosen bracket.
    case fitsBracket(estimateSeconds: Int, bracket: TimeBracket)
    /// A game you're already playing: this much time is left.
    case remainingTime(remainingSeconds: Int)
    /// Well regarded by the crowd (IGDB aggregated rating, 0…100).
    case crowdRated(rating: Double, count: Int?)
    /// No IGDB match — suggested on time fit alone.
    case noMetadata
    /// Thin evidence behind this pick.
    case weakEvidence
    /// Owned only through PS Plus — the licence leaves with the subscription (PLAN §13.3).
    case leavesWithSubscription
    /// A library game that is a ★ favourite on the owner's Batocera box, still unplayed —
    /// a modest backlog boost (PLAN §15).
    case batoceraFavourite
    /// A never-played Batocera favourite pinned at the head of the Discover row (PLAN §15).
    case batoceraFavouritePinned
    /// A PS Plus game with a cancellation date set — "leaves with PS Plus · ~N months left ·
    /// about H h for you" (PLAN §16). `monthsLeft` / `personalLengthSeconds` are nil when
    /// unknown, and the formatter omits those clauses.
    case leavesWithSubscriptionDeadline(monthsLeft: Int?, personalLengthSeconds: Int?)
}

// MARK: - Suggestion + result

/// One Play Next suggestion for the UI (PLAN §7b UI). Carries the engine's verdict
/// (score / match strength / reasons) plus the display facts the store loaded from
/// the DB (title, cover, platform/format). Foundation-only.
struct PlayNextSuggestion: Hashable, Sendable, Identifiable {
    var id: GameID
    var title: String
    var year: Int?
    var coverFile: String?
    /// Platform slugs the game is owned on (for the platform/format line).
    var platformIDs: [String]
    /// The format(s) it's owned as (physical / digital / rom).
    var formats: [ProductFormat]
    var status: PlayStatus?

    /// The estimate used for the bracket (resolved for completionist mode; for a
    /// `playing` game this is the *remaining* time). `nil` ⇒ unknown-length lane.
    var estimateSeconds: Int?
    /// The full estimate before subtracting playtime (for the me-vs-estimate bar).
    var fullEstimateSeconds: Int?

    var score: Double
    var matchStrength: MatchStrength
    var reasons: [PlayNextReason]
    /// False when the game has no IGDB metadata (flagged "no metadata").
    var hasMetadata: Bool

    init(
        id: GameID,
        title: String,
        year: Int? = nil,
        coverFile: String? = nil,
        platformIDs: [String] = [],
        formats: [ProductFormat] = [],
        status: PlayStatus? = nil,
        estimateSeconds: Int? = nil,
        fullEstimateSeconds: Int? = nil,
        score: Double,
        matchStrength: MatchStrength,
        reasons: [PlayNextReason],
        hasMetadata: Bool
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.coverFile = coverFile
        self.platformIDs = platformIDs
        self.formats = formats
        self.status = status
        self.estimateSeconds = estimateSeconds
        self.fullEstimateSeconds = fullEstimateSeconds
        self.score = score
        self.matchStrength = matchStrength
        self.reasons = reasons
        self.hasMetadata = hasMetadata
    }
}

/// Counts of candidates that were dropped, so the UI can explain the shortlist
/// size (PLAN §7b "excluded counts").
struct RecommendationExclusions: Hashable, Sendable {
    var byTime: Int = 0        // outside the bracket (beyond the hard limit)
    var byStatus: Int = 0      // abandoned/played-without-status filtered out
    var byFeedback: Int = 0    // snoozed or nevered
    var unknownLength: Int = 0 // no estimate → unknown-length lane

    var total: Int { byTime + byStatus + byFeedback }
}

/// The engine's answer (PLAN §7b): a hero pick, up to four alternatives, the
/// unknown-length lane, and what was excluded.
struct PlayNextResult: Hashable, Sendable {
    var hero: PlayNextSuggestion?
    var alternatives: [PlayNextSuggestion]
    var unknownLength: [PlayNextSuggestion]
    var exclusions: RecommendationExclusions
    /// The bracket this result was computed for (echoed for the UI).
    var bracket: TimeBracket

    init(
        hero: PlayNextSuggestion? = nil,
        alternatives: [PlayNextSuggestion] = [],
        unknownLength: [PlayNextSuggestion] = [],
        exclusions: RecommendationExclusions = RecommendationExclusions(),
        bracket: TimeBracket
    ) {
        self.hero = hero
        self.alternatives = alternatives
        self.unknownLength = unknownLength
        self.exclusions = exclusions
        self.bracket = bracket
    }

    /// The shortlist that drove the pick (hero + alternatives), in engine order —
    /// what the "Ask Claude" second opinion re-ranks.
    var shortlist: [PlayNextSuggestion] {
        (hero.map { [$0] } ?? []) + alternatives
    }
}
