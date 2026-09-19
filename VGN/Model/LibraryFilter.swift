import Foundation

/// How the grid is sorted (PLAN §8 toolbar `sort▾`).
enum LibrarySort: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case title
    case year
    case dateAdded
    case tierRank    // tier.sort, then rank_key
    case playtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .year: return "Year"
        case .dateAdded: return "Date Added"
        case .tierRank: return "Tier & Rank"
        case .playtime: return "Playtime"
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
        playtimes: Set<PlaytimeBucket> = [],
        includeNoTimeEstimate: Bool = false,
        platform: String? = nil,
        platforms: Set<String> = [],
        scope: SidebarSelection = .all,
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
        self.playtimes = playtimes
        self.includeNoTimeEstimate = includeNoTimeEstimate
        self.platform = platform
        self.platforms = platforms
        self.scope = scope
        self.sort = sort
        self.ascending = ascending
    }

    /// True when nothing but the scope constrains the query (used to decide
    /// whether to show "clear filters", empty-state copy, etc.).
    var hasActiveFacets: Bool {
        !searchText.isEmpty || !genres.isEmpty || !decades.isEmpty
            || !tierIDs.isEmpty || includeUnrated
            || !statuses.isEmpty || includeNotPlayed || includeNoStatus
            || !formats.isEmpty || includeNotOwned
            || !playtimes.isEmpty || includeNoTimeEstimate
            || platform != nil || !platforms.isEmpty
    }
}
