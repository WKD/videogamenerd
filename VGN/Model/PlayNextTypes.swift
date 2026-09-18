import Foundation

// MARK: - Time commitment bracket

/// The time-commitment bracket the user picks (PLAN §7b Inputs). One of four
/// presets, or a precise custom budget (hours/week × weeks). The `completionist`
/// toggle switches a candidate's estimate from IGDB `normally` to `completely`.
///
/// Foundation-only value; the engine reads `lowerSeconds` / `upperSeconds`.
struct TimeBracket: Hashable, Sendable, Codable {
    enum Preset: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
        case evening        // ≤ 5 h
        case weekOrTwo      // 5–15 h
        case month          // 15–40 h
        case longHaul       // 40 h +

        var id: String { rawValue }

        var label: String {
            switch self {
            case .evening: return "An evening"
            case .weekOrTwo: return "A week or two"
            case .month: return "A month"
            case .longHaul: return "A long haul"
            }
        }

        /// Inclusive hour bounds; `nil` = unbounded on that side.
        var lowerHours: Double? {
            switch self {
            case .evening: return nil
            case .weekOrTwo: return 5
            case .month: return 15
            case .longHaul: return 40
            }
        }
        var upperHours: Double? {
            switch self {
            case .evening: return 5
            case .weekOrTwo: return 15
            case .month: return 40
            case .longHaul: return nil
            }
        }
    }

    /// The chosen preset, or `nil` for a custom budget.
    var preset: Preset?
    /// Precise mode: a total budget in seconds (upper bound, no lower bound).
    var customBudgetSeconds: Int?
    /// Estimate `completely` instead of `normally`.
    var completionist: Bool

    init(preset: Preset, completionist: Bool = false) {
        self.preset = preset
        self.customBudgetSeconds = nil
        self.completionist = completionist
    }

    init(budgetSeconds: Int, completionist: Bool = false) {
        self.preset = nil
        self.customBudgetSeconds = budgetSeconds
        self.completionist = completionist
    }

    private static let secondsPerHour = 3600.0

    /// Lower bound in seconds (`nil` = no lower bound / anything shorter is fine).
    var lowerSeconds: Int? {
        if preset == nil { return nil }               // custom budget: no lower bound
        guard let h = preset?.lowerHours else { return nil }
        return Int(h * Self.secondsPerHour)
    }

    /// Upper bound in seconds (`nil` = unbounded, e.g. "a long haul").
    var upperSeconds: Int? {
        if let custom = customBudgetSeconds { return custom }
        guard let h = preset?.upperHours else { return nil }
        return Int(h * Self.secondsPerHour)
    }

    /// A short label for reasons / display.
    var label: String {
        if let preset { return preset.label }
        if let budget = customBudgetSeconds {
            return "~\(Int((Double(budget) / Self.secondsPerHour).rounded())) h budget"
        }
        return "Any length"
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
