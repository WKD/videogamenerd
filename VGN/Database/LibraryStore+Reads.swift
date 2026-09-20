import Foundation
import GRDB

/// Read side of the library: `ValueObservation`s exposed as `AsyncSequence`
/// (the UI lane subscribes to these) plus one-shot fetch variants. All observed
/// values are Foundation-only value types from `VGN/Model/`.
extension LibraryStore {
    var dbReader: any DatabaseReader { database.dbWriter }

    // MARK: - Sidebar counts

    /// Live sidebar counts (PLAN §8). One observation; the scalar smart-list
    /// counts come from a single aggregate query and the per-platform counts
    /// from one grouped query, combined into the emitted value.
    func sidebarCounts() -> AsyncValueObservation<SidebarCounts> {
        ValueObservation.tracking { db in try Self.fetchSidebarCounts(db) }
            .values(in: dbReader)
    }

    /// One-shot sidebar counts.
    func sidebarCountsOnce() async throws -> SidebarCounts {
        try await dbReader.read { db in try Self.fetchSidebarCounts(db) }
    }

    static func fetchSidebarCounts(_ db: Database) throws -> SidebarCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                COUNT(*) AS all_count,
                COALESCE(SUM(owned), 0) AS owned,
                COALESCE(SUM(played), 0) AS played,
                COALESCE(SUM(owned = 1 AND played = 0), 0) AS backlog,
                COALESCE(SUM(played = 1 AND tier_id IS NULL), 0) AS unranked,
                COALESCE(SUM(played = 1 AND tier_id IS NOT NULL AND rank_key IS NULL), 0) AS duel
            FROM (
                SELECT g.id, g.played, g.tier_id, g.rank_key,
                       EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id) AS owned
                FROM games g
            )
            """)!
        var perPlatform: [String: Int] = [:]
        // Per-platform counts use the ONE effective-platform rule (PLAN §4), same as the pills.
        let rows = try Row.fetchAll(db, sql: """
            SELECT platform_id AS pid, COUNT(DISTINCT game_id) AS n
            FROM (\(LibraryQuery.effectivePlatformsSQL)) GROUP BY platform_id
            """)
        for r in rows { perPlatform[r["pid"]] = r["n"] }
        return SidebarCounts(
            all: row["all_count"], owned: row["owned"], played: row["played"],
            backlog: row["backlog"], unranked: row["unranked"], duelQueue: row["duel"],
            perPlatform: perPlatform
        )
    }

    // MARK: - Grid

    /// Live grid rows for `filter` (PLAN §8). Single SQL query, no N+1.
    func games(filter: LibraryFilter) -> AsyncValueObservation<[GameSummary]> {
        ValueObservation.tracking { db in try Self.fetchGames(filter, db) }
            .values(in: dbReader)
    }

    /// One-shot grid rows for `filter`.
    func gamesOnce(filter: LibraryFilter) async throws -> [GameSummary] {
        try await dbReader.read { db in try Self.fetchGames(filter, db) }
    }

    static func fetchGames(_ filter: LibraryFilter, _ db: Database) throws -> [GameSummary] {
        // "Bundles to Expand" (PLAN §5.1): its candidate rule is a Swift title heuristic, so the
        // ids are computed here inside the same read (the observation re-runs on any relevant
        // write, keeping the grid live) and handed to the query as an id restriction.
        var restrictToIDs: [Int64]?
        if case .bundlesToExpand = filter.scope {
            restrictToIDs = try fetchBundleExpansionCandidateIDs(db)
        }
        let (sql, arguments) = LibraryQuery.gamesSQL(filter, restrictToIDs: restrictToIDs)
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(LibraryQuery.gameSummary(from:))
    }

    // MARK: - Detail

    /// The rich inspector value for one game (PLAN §8). One-shot; also available
    /// as an observation.
    func gameDetail(id: Int64) async throws -> GameDetail? {
        try await dbReader.read { db in try Self.fetchGameDetail(id, db) }
    }

    func gameDetailObservation(id: Int64) -> AsyncValueObservation<GameDetail?> {
        ValueObservation.tracking { db in try Self.fetchGameDetail(id, db) }
            .values(in: dbReader)
    }

    static func fetchGameDetail(_ id: Int64, _ db: Database) throws -> GameDetail? {
        guard let g = try Row.fetchOne(db, sql: """
            SELECT g.*, g.decade AS decade,
                   t.letter AS tier_letter, t.label AS tier_label, t.color AS tier_color
            FROM games g LEFT JOIN tiers t ON t.id = g.tier_id
            WHERE g.id = ?
            """, arguments: [id]) else { return nil }

        let genres = try String.fetchAll(db, sql: """
            SELECT ge.name FROM game_genres gg JOIN genres ge ON ge.id = gg.genre_id
            WHERE gg.game_id = ? ORDER BY ge.name
            """, arguments: [id])

        // The inspector's platform list uses the ONE effective-platform rule (PLAN §4).
        let platformIDs = try String.fetchAll(db, sql: """
            SELECT platform_id FROM (\(LibraryQuery.effectivePlatformsSQL))
            WHERE game_id = ?1 ORDER BY platform_id
            """, arguments: [id])

        let copyRows = try Row.fetchAll(db, sql: """
            SELECT p.id AS product_id, p.platform_id, p.format, p.kind, p.title,
                   p.edition, p.region, p.source, p.external_id, p.subscription, pg.position,
                   (SELECT COUNT(*) FROM product_games x WHERE x.product_id = p.id) AS member_count
            FROM product_games pg JOIN products p ON p.id = pg.product_id
            WHERE pg.game_id = ? ORDER BY p.id
            """, arguments: [id])
        let copies: [GameDetail.Copy] = try copyRows.map { r in
            let productID: Int64 = r["product_id"]
            let memberCount: Int = r["member_count"]
            var memberTitles: [String] = []
            var memberIDs: [Int64] = []
            var collectionPlaytimeS: Int?
            // Only a compilation copy needs its full member list (PLAN §8 — the
            // all-or-nothing ownership names every affected game).
            if memberCount > 1 {
                let members = try Self.fetchCompilationMembers(productID, db)
                memberTitles = members.map(\.title)
                memberIDs = members.map(\.gameID)
                // The whole-collection PSN play time (PLAN §13.3 / D2) — resolved here in the
                // detail read, so the inspector never touches the DB from a `body`. nil unless the
                // copy came from an importer that recorded a collection play time not routed to one
                // member (only PSN today).
                if let source: String = r["source"], let externalID: String = r["external_id"] {
                    collectionPlaytimeS = try Self.collectionPlaytimeSeconds(
                        source: source, externalID: externalID, db: db)
                }
            }
            return GameDetail.Copy(
                productID: productID,
                platformID: r["platform_id"],
                format: ProductFormat(rawValue: r["format"]) ?? .physical,
                kind: ProductKind(rawValue: r["kind"]) ?? .single,
                title: r["title"],
                edition: r["edition"],
                region: r["region"],
                source: ProductSource(rawValue: r["source"]) ?? .manual,
                subscription: ProductSubscription(storage: r["subscription"]),
                position: r["position"],
                memberCount: memberCount,
                memberTitles: memberTitles,
                memberIDs: memberIDs,
                collectionPlaytimeS: collectionPlaytimeS
            )
        }

        let statusRaw: String? = g["status"]
        let revisit = (g["revisit"] as Int64?) == 1
        let owned = !copies.isEmpty
        let userEdited = UserEditedFields(raw: (g["user_edited"] as String?) ?? "")
        return GameDetail(
            id: g["id"],
            igdbID: g["igdb_id"],
            title: g["title"],
            sortTitle: g["sort_title"],
            summary: g["summary"],
            releaseDate: g["release_date"],
            year: g["year"],
            decade: g["decade"],
            played: g["played"],
            owned: owned,
            status: PlayStatus.from(dbStatus: statusRaw, revisit: revisit),
            tierID: g["tier_id"],
            tierLetter: g["tier_letter"],
            tierLabel: g["tier_label"],
            tierColorHex: g["tier_color"],
            rankKey: g["rank_key"],
            coverFile: g["cover_file"],
            igdbCoverImageID: g["igdb_cover_image_id"],
            userEditedCover: userEdited.contains(.cover),
            genres: genres,
            platformIDs: platformIDs,
            myPlaytimeS: g["my_playtime_s"],
            psnPlaytimeS: g["psn_playtime_s"],
            ttbHastilyS: g["ttb_hastily_s"],
            ttbNormallyS: g["ttb_normally_s"],
            ttbCompletelyS: g["ttb_completely_s"],
            ttbSource: g["ttb_source"],
            hltbID: g["hltb_id"],
            origin: GameOrigin(storage: g["origin"]),
            firstPlayedAt: g["first_played_at"],
            lastPlayedAt: g["last_played_at"],
            addedAt: g["added_at"],
            updatedAt: g["updated_at"],
            copies: copies
        )
    }

    // MARK: - Platforms & tiers

    /// Platforms that have ≥ 1 game (sidebar), in `group` then `sort` order.
    func platformsInUse() -> AsyncValueObservation<[PlatformInfo]> {
        ValueObservation.tracking { db in try Self.fetchPlatformsInUse(db) }
            .values(in: dbReader)
    }

    func platformsInUseOnce() async throws -> [PlatformInfo] {
        try await dbReader.read { db in try Self.fetchPlatformsInUse(db) }
    }

    static func fetchPlatformsInUse(_ db: Database) throws -> [PlatformInfo] {
        // A platform appears in the sidebar iff a game is *effectively* on it (PLAN §4),
        // so a stale copy-only row never leaves an empty platform in the list.
        try PlatformRecord.fetchAll(db, sql: """
            SELECT * FROM platforms WHERE id IN (
                SELECT DISTINCT platform_id FROM (\(LibraryQuery.effectivePlatformsSQL))
            ) ORDER BY group_name, sort
            """).map(\.info)
    }

    /// All platforms (for pickers), `group` then `sort`.
    func allPlatforms() async throws -> [PlatformInfo] {
        try await dbReader.read { db in
            try PlatformRecord.fetchAll(db, sql: "SELECT * FROM platforms ORDER BY group_name, sort")
                .map(\.info)
        }
    }

    /// All tiers, best → worst.
    func tiers() async throws -> [TierInfo] {
        try await dbReader.read { db in
            try TierRecord.order(sql: "sort").fetchAll(db).compactMap(\.info)
        }
    }

    func tiersObservation() -> AsyncValueObservation<[TierInfo]> {
        ValueObservation.tracking { db in
            try TierRecord.order(sql: "sort").fetchAll(db).compactMap(\.info)
        }.values(in: dbReader)
    }

    // MARK: - Platform lookups (services lane)

    /// The platform whose IGDB id set contains `igdbID` (PLAN §5.6). Used by the
    /// IGDB / cover services to map an IGDB platform to a VGN slug.
    func platform(igdbID: Int) async throws -> PlatformInfo? {
        try await dbReader.read { db in
            try PlatformRecord.fetchAll(db).first { $0.igdbIDs.contains(igdbID) }?.info
        }
    }

    /// The libretro-thumbnails repo for a platform slug, if any (PLAN §5.2).
    func libretroRepo(for platformID: String) async throws -> String? {
        try await dbReader.read { db in
            try String.fetchOne(db, sql: "SELECT libretro_repo FROM platforms WHERE id = ?",
                                arguments: [platformID])
        }
    }
}
