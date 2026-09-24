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
    /// `pace` sets the "By Length" shelf edges and `style` a game's personal length;
    /// a change to either re-subscribes this one observation (never adds a second) so
    /// the shelf counts update.
    func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts>

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

    /// The member game ids of a compilation product ("Show compilation" selects
    /// them all — PLAN §8).
    func compilationMemberIDs(productID: Int64) async -> [Int64]

    /// Live derived-score line for one game (inspector — PLAN §7). Re-yields after
    /// any duel / drag / divider move so "#4 overall" stays current.
    func scoreLineStream(for gameID: Int64) -> AsyncStream<DerivedScoreLine?>

    /// Live map of every tiered game's derived 1–10 score, for the grid badge
    /// tooltips (PLAN §7). Re-yields after any tier/rank change. Scores are never
    /// stored — always derived from the ranking snapshot.
    func scoresStream() -> AsyncStream<[Int64: DerivedScoreValue]>

    /// A cheap aggregate snapshot for the sidebar stats popover (PLAN §6.4).
    func libraryStats() async -> LibraryStats

    /// Live present-entry counts of **The Vault**, per source (PLAN §16). A **separate**
    /// observation from `sidebarCounts` — the Vault is a distinct shelf, so its writes never
    /// disturb the library counts stream and its numbers never enter `SidebarCounts`. One
    /// observation feeds both THE VAULT rows and their visibility.
    func vaultSourceCounts() -> AsyncStream<VaultSourceCounts>
}

extension LibraryDataSource {
    // Defaults so preview sources need not implement these explicitly.
    func compilationMemberIDs(productID: Int64) async -> [Int64] { [] }
    func scoreLineStream(for gameID: Int64) -> AsyncStream<DerivedScoreLine?> { onceStream(nil) }
    func scoresStream() -> AsyncStream<[Int64: DerivedScoreValue]> { onceStream([:]) }
    func libraryStats() async -> LibraryStats { .empty }
    /// Preview / non-Vault sources report an empty Vault (both THE VAULT rows hide).
    func vaultSourceCounts() -> AsyncStream<VaultSourceCounts> { onceStream(VaultSourceCounts()) }
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
        case .playNext: break   // renders its own recommendation view
        case .unlinked:
            // GameSummary carries no igdb_id, so the preview/in-memory evaluator cannot
            // tell linked from unlinked — treat as "no constraint" (the live SQL scopes
            // it for real). See PreviewLibraryDataSource / SidebarCounts.derive.
            break
        case .bundlesToExpand:
            // The candidate rule is a store-side title heuristic over the whole library; a
            // GameSummary can't reproduce it, so the preview/in-memory evaluator treats this as
            // "no constraint" (like .unlinked). The live path scopes it via the id set, and in
            // sample mode the count stays 0 so the row is hidden — documented, not a bug.
            break
        case .needsHoldsUpRating: if !game.needsHoldsUpRating { return false }
        case .dlcAndExpansions, .sameGameTwoEntries:
            // Cached IGDB-type review lists (PLAN §5.1): a GameSummary carries no game_type or
            // parent link, so the preview/in-memory evaluator can't reproduce them — "no
            // constraint" (like .unlinked). The live SQL scopes them; sample counts stay 0.
            break
        case .length, .unmeasured:
            // GameSummary carries no time-to-beat estimate, so the preview/in-memory
            // evaluator cannot band by length — treat these scopes as "no constraint"
            // (the live SQL bands them for real). See PreviewLibraryDataSource.
            break
        case .tierBoard, .theTop, .duel:
            // Ranking destinations render a placeholder, not the grid; scope to
            // played games so any incidental query is still sensible.
            if !game.played { return false }
        case .vault:
            // The Vault renders its own browser (a separate table), never the grid.
            return false
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
        // Tier (OR within kind: any selected tier, plus "Unrated" = played, no tier).
        if !filter.tierIDs.isEmpty || filter.includeUnrated {
            let inSet = game.tierID.map(filter.tierIDs.contains) ?? false
            let isUnrated = filter.includeUnrated && game.played && game.tierID == nil
            if !(inSet || isUnrated) { return false }
        }
        // Completion (OR within kind: any selected status, "Not Played", "No Status").
        if !filter.statuses.isEmpty || filter.includeNotPlayed || filter.includeNoStatus {
            let inSet = game.status.map(filter.statuses.contains) ?? false
            let isNotPlayed = filter.includeNotPlayed && !game.played
            let isNoStatus = filter.includeNoStatus && game.played && game.status == nil
            if !(inSet || isNotPlayed || isNoStatus) { return false }
        }
        // Holds up today? (OR within kind: any selected mark, plus "Unrated" = played, no mark).
        if !filter.holdsUp.isEmpty || filter.includeHoldsUpUnrated {
            let inSet = game.holdsUp.map(filter.holdsUp.contains) ?? false
            let isUnrated = filter.includeHoldsUpUnrated && game.needsHoldsUpRating
            if !(inSet || isUnrated) { return false }
        }
        // Ownership: "Not Owned" is evaluable via GameSummary.owned; specific format
        // values are not carried on the summary and stay SQL-only, so a selected
        // format leaves this facet unconstrained here (matches prior behaviour).
        if filter.includeNotOwned, filter.formats.isEmpty, game.owned {
            return false
        }
        // Explicit platform facet (independent of scope)
        if let platform = filter.platform, !game.platformIDs.contains(platform) {
            return false
        }
        // Explicit platform multi-facet (OR within kind).
        if !filter.platforms.isEmpty,
           !game.platformIDs.contains(where: { filter.platforms.contains($0) }) {
            return false
        }
        return true
    }

    static func apply(_ filter: LibraryFilter, to games: [GameSummary]) -> [GameSummary] {
        let filtered = games.filter { matches($0, filter) }
        return sorted(filtered, by: filter.sort, ascending: filter.ascending)
    }

    static func sorted(_ games: [GameSummary], by sort: LibrarySort, ascending: Bool) -> [GameSummary] {
        // A secondary id tiebreak keeps equal keys from jittering between emissions
        // (mirrors the live query's `… , g.id ASC`).
        let ordered: [GameSummary]
        switch sort {
        case .title:
            ordered = games.sorted { a, b in
                let c = a.title.localizedCaseInsensitiveCompare(b.title)
                return c == .orderedSame ? a.id < b.id : c == .orderedAscending
            }
        case .year:
            ordered = games.sorted { a, b in
                let (ya, yb) = (a.year ?? Int.min, b.year ?? Int.min)
                return ya == yb ? a.id < b.id : ya < yb
            }
        case .tierRank:
            ordered = games.sorted { lhs, rhs in
                let l = (lhs.tierID ?? Int64.max, lhs.rankKey ?? Int64.max, lhs.id)
                let r = (rhs.tierID ?? Int64.max, rhs.rankKey ?? Int64.max, rhs.id)
                return l < r
            }
        case .dateAdded, .playtime, .length, .lastPlayed:
            // No date/playtime/estimate/last-played on GameSummary — keep a stable id order.
            ordered = games.sorted { $0.id < $1.id }
        }
        return ascending ? ordered : ordered.reversed()
    }
}

// MARK: - Sidebar counts derivation (preview only)

extension SidebarCounts {
    /// Derive counts from a full game set — used by the preview source and its
    /// tests. The live counts come from a lane-A aggregate observation.
    ///
    /// The "By Length" shelf counts and the "Unmeasured" count are left at 0 here:
    /// a `GameSummary` carries no time-to-beat estimate, so a preview cannot band by
    /// length (the live SQL does). In sample mode every shelf therefore reads 0 and
    /// the Unmeasured row stays hidden — documented, not a bug.
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
            perPlatform: perPlatform,
            lengthShelves: [:],
            unmeasured: 0,
            needsHoldsUpRating: games.filter(\.needsHoldsUpRating).count
        )
    }
}
