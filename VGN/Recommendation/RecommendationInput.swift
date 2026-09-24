import Foundation

/// A game the user has ranked — the taste training data (PLAN §7b). `score` is its
/// 0…1 taste score (rank percentile / tier midpoint); `traits` includes the
/// synthesised genre / platform / decade features alongside the persisted ones.
struct RankedGame: Hashable, Sendable {
    var id: GameID
    var igdbID: Int64?
    var score: Double
    var traits: [GameTrait]
    /// The importer-filled first-played year (v9), or nil when unknown — used ONLY by the
    /// backtest's optional cutoff (PLAN §7b "Helping me judge"); never a taste signal.
    var firstPlayedYear: Int?

    init(id: GameID, igdbID: Int64? = nil, score: Double, traits: [GameTrait] = [],
         firstPlayedYear: Int? = nil) {
        self.id = id
        self.igdbID = igdbID
        self.score = score
        self.traits = traits
        self.firstPlayedYear = firstPlayedYear
    }

    /// The IGDB ids listed in this game's `similar_games`.
    var similarIGDBIDs: [Int64] { traits.compactMap(\.similarGameID) }
}

/// A game eligible to be recommended (PLAN §7b Candidates): owned (any format,
/// incl. ROMs and compilation members) and not finished/completed. Carries the
/// facts the engine scores on **and** the display facts it echoes into a
/// ``PlayNextSuggestion`` (so the store maps DB → engine → UI once).
struct Candidate: Hashable, Sendable {
    var id: GameID
    var igdbID: Int64?
    var traits: [GameTrait]

    /// IGDB `normally` time-to-beat in seconds (nil ⇒ unknown length).
    var estimateSeconds: Int?
    /// IGDB `completely` time-to-beat (used when the bracket is completionist).
    var completionistSeconds: Int?
    /// The user's own playtime so far (remaining time for a `playing` game).
    var myPlaytimeSeconds: Int?

    var status: RecCandidateStatus
    var igdbRating: Double?
    var ratingCount: Int?
    /// False when there is no IGDB match at all (manual entry / obscure ROM).
    var hasMetadata: Bool

    // Display facts (echoed into the suggestion).
    var title: String
    var year: Int?
    var coverFile: String?
    var platformIDs: [String]
    var formats: [ProductFormat]
    var playStatus: PlayStatus?
    /// The game is owned **only** through a subscription (every owned copy is a PS Plus
    /// claim) — it "leaves with PS Plus" (PLAN §13.3). Feeds the optional, gated
    /// "Prefer expiring PS Plus games" score term. Default false.
    var ownedOnlyViaSubscription: Bool
    /// A library game promoted from — and still ★ favourited on — the owner's Batocera box
    /// (PLAN §15). When unplayed it earns a modest backlog boost and the reason "★ a
    /// favourite on your Batocera". Default false.
    var isBatoceraFavourite: Bool
    /// The owner's "Holds up today?" mark (PLAN §7b) — a fact about how the game plays NOW.
    /// Adjusts this candidate only (bonus / penalty / Too Archaic excluded unless opted in);
    /// never the taste profile, links or the backtest. nil = Unrated (no effect).
    var holdsUp: HoldsUp?
    /// Importer-filled first-played date (v9), echoed to the card as "first played in 1991".
    var firstPlayedAt: Date?

    init(
        id: GameID,
        igdbID: Int64? = nil,
        traits: [GameTrait] = [],
        estimateSeconds: Int? = nil,
        completionistSeconds: Int? = nil,
        myPlaytimeSeconds: Int? = nil,
        status: RecCandidateStatus,
        igdbRating: Double? = nil,
        ratingCount: Int? = nil,
        hasMetadata: Bool = true,
        title: String = "",
        year: Int? = nil,
        coverFile: String? = nil,
        platformIDs: [String] = [],
        formats: [ProductFormat] = [],
        playStatus: PlayStatus? = nil,
        ownedOnlyViaSubscription: Bool = false,
        isBatoceraFavourite: Bool = false,
        holdsUp: HoldsUp? = nil,
        firstPlayedAt: Date? = nil
    ) {
        self.id = id
        self.igdbID = igdbID
        self.traits = traits
        self.estimateSeconds = estimateSeconds
        self.completionistSeconds = completionistSeconds
        self.myPlaytimeSeconds = myPlaytimeSeconds
        self.status = status
        self.igdbRating = igdbRating
        self.ratingCount = ratingCount
        self.hasMetadata = hasMetadata
        self.title = title
        self.year = year
        self.coverFile = coverFile
        self.platformIDs = platformIDs
        self.formats = formats
        self.playStatus = playStatus
        self.ownedOnlyViaSubscription = ownedOnlyViaSubscription
        self.isBatoceraFavourite = isBatoceraFavourite
        self.holdsUp = holdsUp
        self.firstPlayedAt = firstPlayedAt
    }

    var similarIGDBIDs: [Int64] { traits.compactMap(\.similarGameID) }

    /// The candidate's **personal length** for a play style — a blend of the main
    /// (`estimateSeconds`) and completionist (`completionistSeconds`) estimates (owner
    /// request 2026-09-19). The rushed estimate is never loaded, so a rushed-only game
    /// has neither and lands in the unknown-length lane.
    func personalLength(style: PlayStyle) -> PersonalLength? {
        PersonalLength.compute(normallyS: estimateSeconds, completelyS: completionistSeconds, style: style)
    }

    /// The full personal length before subtracting playtime (the me-vs-estimate bar).
    func fullEstimate(style: PlayStyle) -> Int? {
        personalLength(style: style)?.seconds
    }

    /// The estimate the bracket is tested against: the personal length, minus the
    /// user's playtime when the game is already `playing` — or `toRevisit`, where I've
    /// already put hours in and only the rest remains (PLAN §7b remaining time).
    func bracketEstimate(style: PlayStyle) -> Int? {
        guard let full = fullEstimate(style: style) else { return nil }
        if (status == .playing || status == .toRevisit), let played = myPlaytimeSeconds {
            return max(0, full - played)
        }
        return full
    }
}

/// A candidate's eligibility status (PLAN §7b). `finished` / `completed` games
/// never become candidates (the store filters them), so they are not modelled here.
enum RecCandidateStatus: Hashable, Sendable {
    case backlog        // owned, not played
    case playing
    case abandoned      // opt-in
    case toRevisit      // dropped but flagged "come back to it" — a candidate by default (PLAN §7b)
    case playedUnknown  // played, no status — excluded by default (toggle)
}

/// The "not this one" memory (PLAN §7b `rec_feedback`), as engine values.
struct RecFeedbackState: Hashable, Sendable {
    /// Games snoozed until this instant (seconds since 1970). A game past its
    /// snooze is eligible again.
    var snoozedUntil: [GameID: Double]
    /// Games removed for good.
    var never: Set<GameID>
    /// Games recently picked (a mild rotation penalty).
    var picked: Set<GameID>

    init(snoozedUntil: [GameID: Double] = [:], never: Set<GameID> = [], picked: Set<GameID> = []) {
        self.snoozedUntil = snoozedUntil
        self.never = never
        self.picked = picked
    }
}

/// Options for one `recommend` call (PLAN §7b candidate rules + rotation seed).
struct RecommendationOptions: Hashable, Sendable {
    /// Include `abandoned` games ("give it another go?").
    var includeAbandoned: Bool
    /// Include games played with no completion status ("played" may mean finished).
    var includePlayedWithoutStatus: Bool
    /// Include games the owner marked **Too Archaic** ("Holds up today?", PLAN §7b) — off by
    /// default: they are excluded from the regular picks and counted in
    /// ``RecommendationExclusions/tooArchaic``. When on they compete with the "of its time"
    /// penalty and say why they're here.
    var includeArchaic: Bool
    /// Deterministic rotation seed; changing it re-rolls near-ties (PLAN §7b `R`).
    var seed: UInt64
    /// "Now" for snooze comparison, seconds since 1970.
    var now: Double
    /// Max alternatives beyond the hero (PLAN §7b: "up to 4").
    var maxAlternatives: Int
    /// Max entries in the unknown-length lane.
    var maxUnknownLength: Int
    /// Prefer games owned only via PS Plus (a small, backtest-neutral nudge that only
    /// reorders near-ties, PLAN §13.3 — the "Prioritise PS Plus games" fallback when no
    /// cancellation date is set). Off by default so the taste backtest stays neutral; the UI
    /// passes it on.
    var preferExpiringSubscription: Bool
    /// Months until the owner plans to leave PS Plus (nil ⇒ no date; the constant fallback
    /// above applies instead). When set, PS Plus games get the ``PSPlusDeadlineBoost`` ramp
    /// instead of the constant (PLAN §16). Default nil keeps the backtest neutral.
    var psPlusMonthsLeft: Double?
    /// The owner's weekly pace, for the deadline finishability (§15). Default `.default`.
    var psPlusPace: PlayPace

    init(
        includeAbandoned: Bool = false,
        includePlayedWithoutStatus: Bool = false,
        includeArchaic: Bool = false,
        seed: UInt64 = 0,
        now: Double = Date().timeIntervalSince1970,
        maxAlternatives: Int = 4,
        maxUnknownLength: Int = 8,
        preferExpiringSubscription: Bool = false,
        psPlusMonthsLeft: Double? = nil,
        psPlusPace: PlayPace = .default
    ) {
        self.includeAbandoned = includeAbandoned
        self.includePlayedWithoutStatus = includePlayedWithoutStatus
        self.includeArchaic = includeArchaic
        self.seed = seed
        self.now = now
        self.maxAlternatives = maxAlternatives
        self.maxUnknownLength = maxUnknownLength
        self.preferExpiringSubscription = preferExpiringSubscription
        self.psPlusMonthsLeft = psPlusMonthsLeft
        self.psPlusPace = psPlusPace
    }
}

/// Everything one `recommend` call needs (PLAN §7b). Plain values — no I/O.
struct RecommendationInput: Sendable {
    var ranked: [RankedGame]
    var candidates: [Candidate]
    var bracket: TimeBracket
    var feedback: RecFeedbackState
    var options: RecommendationOptions
    var weights: RecommendationWeights

    init(
        ranked: [RankedGame],
        candidates: [Candidate],
        bracket: TimeBracket,
        feedback: RecFeedbackState = RecFeedbackState(),
        options: RecommendationOptions = RecommendationOptions(),
        weights: RecommendationWeights = RecommendationWeights()
    ) {
        self.ranked = ranked
        self.candidates = candidates
        self.bracket = bracket
        self.feedback = feedback
        self.options = options
        self.weights = weights
    }
}
