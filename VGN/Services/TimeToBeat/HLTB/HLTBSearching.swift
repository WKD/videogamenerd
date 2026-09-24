import Foundation

/// Stable source id for the shared importer cache (`import_cache.source = "hltb"`,
/// PLAN §5.3). Kept local to the HLTB code so the fallback needs no change to the
/// pure Model layer.
enum HLTBSource {
    static let id = "hltb"
}

/// One HowLongToBeat search result — a plain, `Sendable` value the matcher and the
/// fill path consume (PLAN §5.3). Times are in **seconds** (HLTB stores them so; the
/// UI converts). A field is `nil` when HLTB has no data for that play style.
struct HLTBCandidate: Sendable, Hashable, Identifiable, Codable {
    /// The HowLongToBeat game id — persisted so "Open on HowLongToBeat" opens the
    /// exact page.
    var id: Int64
    var name: String
    /// Alternate names HLTB lists (`game_alias`), split into individual titles.
    var aliases: [String]
    /// HLTB `release_world` — the world release year, the matcher's tie-breaker.
    var releaseYear: Int?
    /// HLTB `comp_main` — *Main Story*. See ``mappedTimes`` for where it is written.
    var mainSeconds: Int?
    /// HLTB `comp_plus` — *Main + Extra*.
    var mainExtraSeconds: Int?
    /// HLTB `comp_100` — *Completionist*.
    var completionistSeconds: Int?
    /// Platforms HLTB lists (`profile_platform`), when present.
    var platforms: [String]
    /// HLTB `comp_all` — the *All Styles* average. Used only as a last resort (see
    /// ``mappedTimes``). Optional + additive, so id-keyed cache entries written before wave
    /// 21 still decode (a missing key decodes to nil).
    var allStylesSeconds: Int?
    /// HLTB `comp_main_count` / `comp_plus_count` / `comp_100_count` — how many players
    /// submitted each time ("2 reports"). Display only; optional + additive.
    var mainCount: Int?
    var mainExtraCount: Int?
    var completionistCount: Int?

    init(id: Int64, name: String, aliases: [String] = [], releaseYear: Int? = nil,
         mainSeconds: Int? = nil, mainExtraSeconds: Int? = nil,
         completionistSeconds: Int? = nil, platforms: [String] = [],
         allStylesSeconds: Int? = nil, mainCount: Int? = nil, mainExtraCount: Int? = nil,
         completionistCount: Int? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.releaseYear = releaseYear
        self.mainSeconds = mainSeconds
        self.mainExtraSeconds = mainExtraSeconds
        self.completionistSeconds = completionistSeconds
        self.platforms = platforms
        self.allStylesSeconds = allStylesSeconds
        self.mainCount = mainCount
        self.mainExtraCount = mainExtraCount
        self.completionistCount = completionistCount
    }

    /// Every name to fuzzy-match against (canonical name + aliases).
    var allNames: [String] { [name] + aliases }

    /// The **write rule** (PLAN §5.3, wave 21 D1) — the one place HLTB's columns become
    /// VGN's three times; `applyHLTBTimes` (fill), `replaceHLTBTimes` (replace, incl. Link &
    /// Use) both write exactly this:
    ///
    /// | VGN column          | value                                                        |
    /// |---------------------|--------------------------------------------------------------|
    /// | `ttb_normally_s`    | Main+Extra if > 0, else Main Story if > 0, else All Styles*  |
    /// | `ttb_hastily_s`     | Main Story if > 0, else nil                                  |
    /// | `ttb_completely_s`  | Completionist if > 0, else nil (never fabricated)            |
    ///
    /// Why Main Story fills the main slot: many (mostly retro) games on HLTB carry only a
    /// Main Story time (Akira, NES: `comp_main 2 h 14`, `comp_plus 0`). Writing it only as
    /// the *rushed* time left the game with a rushed-only estimate, which the app's
    /// "rushed-only ⇒ unmeasured" rule then hides entirely. A Main Story time *is* the
    /// game's main story for our purposes.
    ///
    /// *All Styles (`comp_all`) is used for the main slot only when both Main Story and
    /// Main+Extra are absent and it is > 0 — the rare entry with only a mixed average (every
    /// submission tagged as another play style). It is a real average of real runs, better
    /// than no estimate, but less specific than either, hence the last resort; it never
    /// fills rushed or completionist.
    var mappedTimes: HLTBMappedTimes {
        let main = Self.positive(mainSeconds)
        let plus = Self.positive(mainExtraSeconds)
        let full = Self.positive(completionistSeconds)
        let all = (main == nil && plus == nil) ? Self.positive(allStylesSeconds) : nil
        return HLTBMappedTimes(
            hastily: main,
            normally: plus ?? main ?? all,
            completely: full,
            mainStoryUsedForMain: plus == nil && main != nil,
            allStylesUsedForMain: all != nil)
    }

    /// True when HLTB lists a Main Story time but no Main+Extra — the main slot then shows
    /// the Main Story ("Main+Extra not on HowLongToBeat — main story used").
    var usedMainStoryForMain: Bool { mappedTimes.mainStoryUsedForMain }

    /// True when HLTB gave at least one usable time (a zero/absent-everywhere result
    /// carries nothing worth writing).
    var hasAnyTime: Bool { mappedTimes.hasAnyTime }

    private static func positive(_ v: Int?) -> Int? {
        guard let v, v > 0 else { return nil }
        return v
    }
}

/// The three times a HowLongToBeat candidate writes (see ``HLTBCandidate/mappedTimes``).
struct HLTBMappedTimes: Sendable, Equatable {
    var hastily: Int?
    var normally: Int?
    var completely: Int?
    /// Main+Extra missing → the Main Story filled the main slot.
    var mainStoryUsedForMain: Bool = false
    /// Neither Main Story nor Main+Extra → the All Styles average filled the main slot.
    var allStylesUsedForMain: Bool = false

    var hasAnyTime: Bool { hastily != nil || normally != nil || completely != nil }
}

/// Whether a HowLongToBeat lookup may be served from the cache (PLAN §5.3). Caching is
/// for speed and politeness — never a way to send more.
///
/// Wave 21 (D3) removed the old 24 h "refresh floor": a Refresh — single or bulk — is
/// about re-applying VGN's own mapping + matching to HLTB's reply, and HLTB's numbers move
/// slowly, so it serves the cache exactly like Fetch Missing. The only way past a valid
/// cached reply is the explicit, per-game ``bypassOne``; a bulk run never bypasses.
enum HLTBFreshnessPolicy: Sendable, Equatable {
    /// Serve any entry still inside its TTL (180 d found / 30 d no-result) — every Fetch
    /// and every Refresh.
    case cacheFirst
    /// "Ask HowLongToBeat Again": ignore the cache for this one lookup (still stored after).
    /// Single-game only; never used by a bulk run.
    case bypassOne
}

/// A run's cache/network tallies — the "from cache · from network" line (PLAN §5.3).
struct HLTBRequestTally: Sendable, Equatable {
    var fromCache = 0
    var fromNetwork = 0
}

/// The seam behind which the frail HLTB private endpoint lives (PLAN §5.3). Search by
/// title → candidates, remember a chosen candidate under its id (D1/D4), and report cache
/// freshness for the UI. Implemented live by ``HLTBClient`` (actor, serial, paced,
/// budgeted, cached, stop-on-first-unexpected-response) and by an inert fake in sample /
/// seeded / test modes. The whole request mechanic — endpoint discovery, payload, DTO —
/// is isolated in ``HLTBEndpoint`` so a future break has exactly one place to fix.
protocol HLTBSearching: Sendable {
    /// Search HowLongToBeat for `title`. Returns candidates best-effort; a served
    /// cache hit costs zero requests. Throws ``ImportError`` on the first unexpected
    /// response (no retries, no variants).
    func search(title: String) async throws -> [HLTBCandidate]

    /// Search with an explicit freshness policy (D1). The default implementation ignores
    /// the policy (for the inert / fake searchers); ``HLTBClient`` honours it.
    func search(title: String, policy: HLTBFreshnessPolicy) async throws -> [HLTBCandidate]

    /// Persist a chosen / linked candidate under its id-key (`id:<hltbID>`, D1) so a later
    /// exact refresh-by-id is one cached lookup. No-op for the inert searcher.
    func rememberChosen(_ candidate: HLTBCandidate) async

    /// The candidate remembered for a stored HLTB id, if still cached (D4). Its canonical
    /// HLTB `name` seeds an exact refresh; nil falls back to the query ladder.
    func linkedCandidate(hltbID: Int64) async -> HLTBCandidate?

    /// The age of the cached search reply for `title` at `now`, or nil when uncached —
    /// drives the "from cache, 3 h old" caption (D1).
    func cacheAge(title: String, now: Date) async -> TimeInterval?

    /// This searcher's cache/network tallies so far (zero for the inert / fake searchers).
    func requestTally() async -> HLTBRequestTally

    /// The candidates of a still-valid cached reply for `title`, or nil when uncached —
    /// never a request (wave 21 D3: the fill service's cache pass). Default nil.
    func cachedCandidates(title: String) async -> [HLTBCandidate]?
}

extension HLTBSearching {
    func search(title: String, policy: HLTBFreshnessPolicy) async throws -> [HLTBCandidate] {
        try await search(title: title)
    }
    func rememberChosen(_ candidate: HLTBCandidate) async {}
    func linkedCandidate(hltbID: Int64) async -> HLTBCandidate? { nil }
    func cacheAge(title: String, now: Date) async -> TimeInterval? { nil }
    func requestTally() async -> HLTBRequestTally { HLTBRequestTally() }
    func cachedCandidates(title: String) async -> [HLTBCandidate]? { nil }
}
