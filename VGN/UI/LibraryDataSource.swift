import Foundation

/// The seam the UI reads its data through. Each accessor is an `AsyncStream`
/// that yields a fresh value whenever the underlying data changes, so views
/// re-render themselves after any write — no manual refresh (PLAN §9).
///
/// Next wave the GRDB-backed implementation conforms by wrapping its
/// `ValueObservation`s in `AsyncStream`. The DB lane is exposing exactly these
/// shapes: `sidebarCounts()`, `games(filter:)`, `platformsInUse()`, `tiers()`
/// as observations, plus `gameDetail(id:)`. Keep the signatures identical so
/// the swap in `LibraryViewModel` is one line.
protocol LibraryDataSource: Sendable {
    /// Live sidebar aggregate counts (PLAN §8 "one observed aggregate query").
    func sidebarCounts() -> AsyncStream<SidebarCounts>

    /// Platforms with ≥ 1 game, full `PlatformInfo` for grouping/labels.
    func platformsInUse() -> AsyncStream<[PlatformInfo]>

    /// The tier definitions (S A B C D F, editable), best-first.
    func tiers() -> AsyncStream<[TierInfo]>

    /// Genre names present in the library (for the Genre ▾ menu). Re-yields.
    func genresInUse() -> AsyncStream<[String]>

    /// Decades present in the library (for the Decade ▾ menu). Re-yields.
    func decadesInUse() -> AsyncStream<[Int]>

    /// The slim grid rows for a given filter/scope/sort. Re-yields on change.
    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]>

    /// Full detail for one game, one-shot.
    func gameDetail(id: Int64) async -> GameDetail?

    /// Live full detail for one game — the inspector subscribes so it updates
    /// itself after any write to the shown game (PLAN §8/§9).
    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?>
}

/// Emits a single value then finishes — the shape a static/preview source uses.
func onceStream<T: Sendable>(_ value: T) -> AsyncStream<T> {
    AsyncStream { continuation in
        continuation.yield(value)
        continuation.finish()
    }
}

// MARK: - In-memory filtering (preview only)

/// A pure, in-memory evaluation of a `LibraryFilter` over `GameSummary` values.
/// The live app compiles the filter to one SQL query (lane A); this exists only
/// so the preview data source and its tests behave like the real thing. Genres
/// are ignored here (a `GameSummary` carries no genre facet).
enum LibraryFilterEvaluator {
    static func matches(_ game: GameSummary, _ filter: LibraryFilter) -> Bool {
        // Scope
        switch filter.scope {
        case .all: break
        case .owned: if !game.owned { return false }
        case .played: if !game.played { return false }
        case .backlog: if !game.isBacklog { return false }
        case .unranked: if !game.isUnranked { return false }
        case .platform(let slug): if !game.platformIDs.contains(slug) { return false }
        case .tierBoard, .theTop, .duel:
            // Ranking destinations render a placeholder, not the grid; scope to
            // played games so any incidental query is still sensible.
            if !game.played { return false }
        }
        // Text
        if !filter.searchText.isEmpty,
           game.title.range(of: filter.searchText, options: .caseInsensitive) == nil {
            return false
        }
        // Decade
        if !filter.decades.isEmpty {
            guard let year = game.year, filter.decades.contains((year / 10) * 10) else {
                return false
            }
        }
        // Tier
        if !filter.tierIDs.isEmpty {
            guard let tid = game.tierID, filter.tierIDs.contains(tid) else { return false }
        }
        // Status
        if !filter.statuses.isEmpty {
            guard let status = game.status, filter.statuses.contains(status) else { return false }
        }
        // Explicit platform facet (independent of scope)
        if let platform = filter.platform, !game.platformIDs.contains(platform) {
            return false
        }
        return true
    }

    static func apply(_ filter: LibraryFilter, to games: [GameSummary]) -> [GameSummary] {
        let filtered = games.filter { matches($0, filter) }
        return sorted(filtered, by: filter.sort, ascending: filter.ascending)
    }

    static func sorted(_ games: [GameSummary], by sort: LibrarySort, ascending: Bool) -> [GameSummary] {
        let ordered: [GameSummary]
        switch sort {
        case .title:
            ordered = games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .year:
            ordered = games.sorted { ($0.year ?? Int.min) < ($1.year ?? Int.min) }
        case .tierRank:
            ordered = games.sorted { lhs, rhs in
                let l = (lhs.tierID ?? Int64.max, lhs.rankKey ?? Int64.max)
                let r = (rhs.tierID ?? Int64.max, rhs.rankKey ?? Int64.max)
                return l < r
            }
        case .dateAdded, .playtime:
            // No date/playtime on GameSummary — keep a stable id order.
            ordered = games.sorted { $0.id < $1.id }
        }
        return ascending ? ordered : ordered.reversed()
    }
}

// MARK: - Sidebar counts derivation (preview only)

extension SidebarCounts {
    /// Derive counts from a full game set — used by the preview source and its
    /// tests. The live counts come from a lane-A aggregate observation.
    static func derive(from games: [GameSummary]) -> SidebarCounts {
        var perPlatform: [String: Int] = [:]
        for game in games {
            for slug in game.platformIDs { perPlatform[slug, default: 0] += 1 }
        }
        return SidebarCounts(
            all: games.count,
            owned: games.filter(\.owned).count,
            played: games.filter(\.played).count,
            backlog: games.filter(\.isBacklog).count,
            unranked: games.filter(\.isUnranked).count,
            duelQueue: games.filter { $0.played && $0.rankKey == nil }.count,
            perPlatform: perPlatform
        )
    }
}
