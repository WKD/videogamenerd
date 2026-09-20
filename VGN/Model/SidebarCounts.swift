import Foundation

/// Live counts shown next to the sidebar rows (PLAN §8: "live counts, one
/// observed aggregate query"). Produced by a lane-A DB observation.
struct SidebarCounts: Hashable, Sendable {
    var all: Int
    var owned: Int
    var played: Int
    var backlog: Int
    var unranked: Int
    /// Number of games waiting in the duel queue (unplaced + refine pairs).
    var duelQueue: Int
    /// Per-platform game counts, keyed by platform slug. Only platforms with
    /// ≥ 1 game are expected to appear (the sidebar hides empty ones).
    var perPlatform: [String: Int]
    /// Per-length-shelf game counts (PLAN §8). Counts use the time-to-beat
    /// **estimate only**, never the owner's playtime, and depend on the current
    /// ``PlayPace`` (the observation re-runs when the pace changes). A shelf with no
    /// games stays in the sidebar (dimmed), so a missing key reads as 0.
    var lengthShelves: [LengthShelf: Int]
    /// Games with no time-to-beat estimate at all (the "Unmeasured" row).
    var unmeasured: Int
    /// Games not linked to an IGDB entry (`igdb_id IS NULL`) — the "Unlinked" row,
    /// shown only when > 0 (PLAN §5.1). Part of the same single counts query.
    var unlinked: Int
    /// Library games whose title looks like an unexpanded bundle — the "Bundles to Expand" row,
    /// shown only when > 0 (PLAN §5.1). Computed in the same single counts observation, via the
    /// shared candidate rule (``LibraryStore/fetchBundleExpansionCandidates(_:)``).
    var bundlesToExpand: Int
    /// Library games whose cached IGDB type is DLC/expansion/pack/season/update/mod — the
    /// "DLC & Expansions" row, shown only when > 0 (PLAN §5.1). Same single counts observation.
    var dlcAndExpansions: Int
    /// Library games that are an IGDB port whose parent is also in the library — the
    /// "Same Game, Two Entries" row, shown only when > 0 (PLAN §5.1). Same counts observation.
    var sameGameTwoEntries: Int

    init(
        all: Int = 0,
        owned: Int = 0,
        played: Int = 0,
        backlog: Int = 0,
        unranked: Int = 0,
        duelQueue: Int = 0,
        perPlatform: [String: Int] = [:],
        lengthShelves: [LengthShelf: Int] = [:],
        unmeasured: Int = 0,
        unlinked: Int = 0,
        bundlesToExpand: Int = 0,
        dlcAndExpansions: Int = 0,
        sameGameTwoEntries: Int = 0
    ) {
        self.all = all
        self.owned = owned
        self.played = played
        self.backlog = backlog
        self.unranked = unranked
        self.duelQueue = duelQueue
        self.perPlatform = perPlatform
        self.lengthShelves = lengthShelves
        self.unmeasured = unmeasured
        self.unlinked = unlinked
        self.bundlesToExpand = bundlesToExpand
        self.dlcAndExpansions = dlcAndExpansions
        self.sameGameTwoEntries = sameGameTwoEntries
    }

    static let empty = SidebarCounts()

    /// The count to display for a given sidebar row, or nil when that row
    /// shows no badge (Tier Board / The Top).
    func count(for selection: SidebarSelection) -> Int? {
        switch selection {
        case .all: return all
        case .owned: return owned
        case .played: return played
        case .backlog: return backlog
        case .unranked: return unranked
        case .duel: return duelQueue
        case .tierBoard, .theTop, .playNext: return nil
        case .unlinked: return unlinked
        case .bundlesToExpand: return bundlesToExpand
        case .dlcAndExpansions: return dlcAndExpansions
        case .sameGameTwoEntries: return sameGameTwoEntries
        case .length(let shelf): return lengthShelves[shelf] ?? 0
        case .unmeasured: return unmeasured
        // The ROM catalogue is a separate shelf — its count never rides the library counts
        // query (PLAN §15). The sidebar drives its badge from a separate observation.
        case .vault: return nil
        case .platform(let slug): return perPlatform[slug] ?? 0
        }
    }
}
