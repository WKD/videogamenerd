import Foundation

/// How the grid is sorted (PLAN §8 toolbar `sort▾`).
enum LibrarySort: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case title
    case year
    case dateAdded
    case tierRank    // tier.sort, then rank_key
    case playtime    // effective playtime (my/PSN), most-played first
    case length      // time-to-beat *estimate* (how long the game is), NULLs last
    case lastPlayed  // most-recently-played first, NULLs last (PSN import, §13.3)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .year: return "Year"
        case .dateAdded: return "Date Added"
        case .tierRank: return "Tier & Rank"
        case .playtime: return "Playtime"
        case .length: return "Length"
        case .lastPlayed: return "Last Played"
        }
    }

    /// The natural default direction for this sort.
    var defaultAscending: Bool {
        switch self {
        case .title: return true
        case .year: return true
        case .dateAdded: return false   // newest first
        case .tierRank: return true     // best first
        case .playtime: return false    // most-played first
        case .length: return true       // shortest first (the "By Length" default)
        case .lastPlayed: return false  // most-recently-played first
        }
    }
}

/// The compiled library query state (PLAN §8: filters combine AND across
/// kinds, OR within a kind; lane A compiles this to one SQL query).
///
/// Values are plain ids/strings so this type stays free of GRDB and SwiftUI.
struct LibraryFilter: Hashable, Sendable {
    /// FTS5 prefix search text (empty = no text filter).
    var searchText: String

    // Facet sets. Empty set = that facet does not constrain the query.
    var genres: Set<String>
    var decades: Set<Int>
    var tierIDs: Set<Int64>
    /// Also match **Unrated** games — played but with no tier yet (mirrors the
    /// sidebar "Unranked" smart list: `played = 1 AND tier_id IS NULL`). OR-combines
    /// with `tierIDs` within the tier facet (PLAN §8): S + this shows S-tier and
    /// unrated games; alone it shows only unrated games. Unplayed games are found
    /// through the status facet's "Not Played", not here.
    var includeUnrated: Bool
    var statuses: Set<PlayStatus>
    /// Also match games I have **not played** (`played = 0`). OR-combines with
    /// `statuses` within the completion facet.
    var includeNotPlayed: Bool
    /// Also match **played** games with **no** completion status
    /// (`played = 1 AND status IS NULL`) — a played game need not carry a status.
    /// OR-combines within the completion facet.
    var includeNoStatus: Bool
    /// Ownership-format facet (physical / digital / rom). Empty = no constraint;
    /// a game matches if it has ≥ 1 owned product in one of these formats.
    var formats: Set<ProductFormat>
    /// Also match **Not Owned** games — no owned product/copy at all (played-only
    /// games). Uses the same ownership definition as the sidebar "Owned" list
    /// (any owned product, so compilation-owned games count as owned). OR-combines
    /// with `formats` within the format facet.
    var includeNotOwned: Bool

    /// Its own facet (owner request 2026-09-19): match only games I own in **more
    /// than one copy or format** — ≥ 2 owned products (e.g. physical + digital, or
    /// two physical copies). ANDs across kinds like any other facet.
    var multipleCopies: Bool

    /// Its own facet (owner request 2026-09-20): match only games I own in ≥ 2 really-owned
    /// copies (`subscription IS NULL`) that share the **same platform AND format** — e.g. two
    /// physical PS3 discs of the same game. Narrower than ``multipleCopies`` (which counts any
    /// two products, even different platforms/formats). Each product is counted once; a
    /// compilation copy counts as a copy of each of its members. ANDs across kinds.
    var duplicateCopies: Bool

    /// Format ▸ "PS Plus" facet (PLAN §13.3): match only games whose **only** owned copies
    /// are subscription copies (`products.subscription IS NOT NULL`) — the games I own only
    /// through PS Plus, at risk when the subscription lapses. A game also owned on disc is
    /// excluded. Its own facet, ANDed across kinds (like ``multipleCopies``); with Status ▸
    /// Not Played it is the "finish before unsubscribing" list. Wired to the menu by the UI lane.
    var includeSubscriptionOnly: Bool

    /// Playtime-band facet (< 10 h … > 200 h). Empty = no constraint. The value
    /// bucketed is the effective playtime (manual over PSN), falling back to the best
    /// available IGDB estimate (main → rushed → completionist) for a game I have not
    /// played (PLAN §6.4/§8).
    var playtimes: Set<PlaytimeBucket>
    /// Also match games with **no time information at all** — no effective playtime
    /// AND none of the IGDB estimates (main / rushed / completionist). These are the
    /// games a fetched completion time is missing for, which impairs Play Next
    /// (PLAN §5.3). OR-combines with `playtimes` within the playtime facet.
    var includeNoTimeEstimate: Bool

    /// Match only games with a **suspicious time estimate** — implausible / out-of-order
    /// completion times worth refreshing from HowLongToBeat (PLAN §5.3, owner request
    /// 2026-09-20; the rule is ``EstimateSanity``). Its **own** facet, ANDed across kinds
    /// (like ``multipleCopies``), even though it lives in the Playtime menu next to
    /// "No Estimate": a game whose times come from HLTB or that the owner dismissed
    /// ("Estimate Looks Right") is never flagged.
    var includeSuspiciousEstimate: Bool

    /// A single explicit platform facet (slug), independent of the scope.
    /// (Legacy single facet; the multi-select facet below is `platforms`.)
    var platform: String?

    /// Explicit platform multi-select facet (slugs), usable from any scope
    /// including "All" (PLAN §8). Empty = no constraint; a game matches if it is on
    /// **any** of these platforms (OR within the kind). The sidebar platform
    /// selection stays the primary way to scope; this is the toolbar filter.
    var platforms: Set<String>

    /// The smart-list / platform scope selected in the sidebar.
    var scope: SidebarSelection

    /// The owner's weekly play pace, which sets the hour edges of the "By Length"
    /// scopes (``SidebarSelection/length(_:)`` / ``SidebarSelection/unmeasured``).
    /// Carried on the filter so the grid query can resolve a length scope's bounds
    /// from the *same* value the counts use, and so a pace change re-runs the grid
    /// like any other filter change. Not a facet — it never appears in
    /// ``hasActiveFacets`` and only constrains a length scope.
    var playPace: PlayPace

    /// The owner's play style, which sets each game's **personal length** (a blend of
    /// the main and completionist estimates — owner request 2026-09-19). Carried on the
    /// filter so the "By Length" scopes, the Length sort and the Playtime filter's
    /// unplayed fallback all resolve length from the *same* value the counts use, and so
    /// a style change re-runs the grid like a filter change. Not a facet.
    ///
    /// The **default is `.storyFirst`** (t = 0 ⇒ personal length = the raw main-story
    /// estimate) so a bare filter bands by the plain `normally` time; the app always
    /// injects the owner's real style (``PlayStyle/default`` = lots of side quests)
    /// through ``LibraryViewModel``, and "Clear all" preserves it.
    var playStyle: PlayStyle

    var sort: LibrarySort
    var ascending: Bool

    init(
        searchText: String = "",
        genres: Set<String> = [],
        decades: Set<Int> = [],
        tierIDs: Set<Int64> = [],
        includeUnrated: Bool = false,
        statuses: Set<PlayStatus> = [],
        includeNotPlayed: Bool = false,
        includeNoStatus: Bool = false,
        formats: Set<ProductFormat> = [],
        includeNotOwned: Bool = false,
        multipleCopies: Bool = false,
        duplicateCopies: Bool = false,
        includeSubscriptionOnly: Bool = false,
        playtimes: Set<PlaytimeBucket> = [],
        includeNoTimeEstimate: Bool = false,
        includeSuspiciousEstimate: Bool = false,
        platform: String? = nil,
        platforms: Set<String> = [],
        scope: SidebarSelection = .all,
        playPace: PlayPace = .default,
        playStyle: PlayStyle = .storyFirst,
        sort: LibrarySort = .title,
        ascending: Bool = true
    ) {
        self.searchText = searchText
        self.genres = genres
        self.decades = decades
        self.tierIDs = tierIDs
        self.includeUnrated = includeUnrated
        self.statuses = statuses
        self.includeNotPlayed = includeNotPlayed
        self.includeNoStatus = includeNoStatus
        self.formats = formats
        self.includeNotOwned = includeNotOwned
        self.multipleCopies = multipleCopies
        self.duplicateCopies = duplicateCopies
        self.includeSubscriptionOnly = includeSubscriptionOnly
        self.playtimes = playtimes
        self.includeNoTimeEstimate = includeNoTimeEstimate
        self.includeSuspiciousEstimate = includeSuspiciousEstimate
        self.platform = platform
        self.platforms = platforms
        self.scope = scope
        self.playPace = playPace
        self.playStyle = playStyle
        self.sort = sort
        self.ascending = ascending
    }

    /// True when nothing but the scope constrains the query (used to decide
    /// whether to show "clear filters", empty-state copy, etc.).
    var hasActiveFacets: Bool {
        !searchText.isEmpty || !genres.isEmpty || !decades.isEmpty
            || !tierIDs.isEmpty || includeUnrated
            || !statuses.isEmpty || includeNotPlayed || includeNoStatus
            || !formats.isEmpty || includeNotOwned || multipleCopies || duplicateCopies || includeSubscriptionOnly
            || !playtimes.isEmpty || includeNoTimeEstimate || includeSuspiciousEstimate
            || platform != nil || !platforms.isEmpty
    }
}
