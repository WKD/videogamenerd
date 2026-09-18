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
    var statuses: Set<PlayStatus>
    /// Ownership-format facet (physical / digital / rom). Empty = no constraint;
    /// a game matches if it has ≥ 1 owned product in one of these formats.
    var formats: Set<ProductFormat>

    /// Playtime-band facet (< 10 h / 10–40 h / > 40 h). Empty = no constraint. The
    /// value bucketed is the effective playtime (manual over PSN), falling back to
    /// the IGDB main estimate for a game I have not played (PLAN §6.4).
    var playtimes: Set<PlaytimeBucket>

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
        statuses: Set<PlayStatus> = [],
        formats: Set<ProductFormat> = [],
        playtimes: Set<PlaytimeBucket> = [],
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
        self.statuses = statuses
        self.formats = formats
        self.playtimes = playtimes
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
            || !tierIDs.isEmpty || !statuses.isEmpty || !formats.isEmpty
            || !playtimes.isEmpty || platform != nil || !platforms.isEmpty
    }
}
