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
struct HLTBCandidate: Sendable, Hashable, Identifiable {
    /// The HowLongToBeat game id — persisted so "Open on HowLongToBeat" opens the
    /// exact page.
    var id: Int64
    var name: String
    /// Alternate names HLTB lists (`game_alias`), split into individual titles.
    var aliases: [String]
    /// HLTB `release_world` — the world release year, the matcher's tie-breaker.
    var releaseYear: Int?
    /// HLTB `comp_main` → *Main Story* → `ttb_hastily_s`.
    var mainSeconds: Int?
    /// HLTB `comp_plus` → *Main + Extra* → `ttb_normally_s`.
    var mainExtraSeconds: Int?
    /// HLTB `comp_100` → *Completionist* → `ttb_completely_s`.
    var completionistSeconds: Int?
    /// Platforms HLTB lists (`profile_platform`), when present.
    var platforms: [String]

    init(id: Int64, name: String, aliases: [String] = [], releaseYear: Int? = nil,
         mainSeconds: Int? = nil, mainExtraSeconds: Int? = nil,
         completionistSeconds: Int? = nil, platforms: [String] = []) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.releaseYear = releaseYear
        self.mainSeconds = mainSeconds
        self.mainExtraSeconds = mainExtraSeconds
        self.completionistSeconds = completionistSeconds
        self.platforms = platforms
    }

    /// Every name to fuzzy-match against (canonical name + aliases).
    var allNames: [String] { [name] + aliases }

    /// True when HLTB gave at least one usable time (a zero/absent-everywhere result
    /// carries nothing worth writing).
    var hasAnyTime: Bool {
        (mainSeconds ?? 0) > 0 || (mainExtraSeconds ?? 0) > 0 || (completionistSeconds ?? 0) > 0
    }
}

/// The seam behind which the frail HLTB private endpoint lives (PLAN §5.3). One
/// method: search by title → candidates. Implemented live by ``HLTBClient`` (actor,
/// serial, paced, budgeted, cached, stop-on-first-unexpected-response) and by an
/// inert fake in sample / seeded / test modes. The whole request mechanic — endpoint
/// discovery, payload, DTO — is isolated in ``HLTBEndpoint`` so a future break has
/// exactly one place to fix.
protocol HLTBSearching: Sendable {
    /// Search HowLongToBeat for `title`. Returns candidates best-effort; a served
    /// cache hit costs zero requests. Throws ``ImportError`` on the first unexpected
    /// response (no retries, no variants).
    func search(title: String) async throws -> [HLTBCandidate]
}
