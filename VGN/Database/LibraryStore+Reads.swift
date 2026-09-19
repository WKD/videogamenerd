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
        let rows = try Row.fetchAll(db, sql: """
            SELECT platform_id AS pid, COUNT(DISTINCT game_id) AS n FROM (
                SELECT platform_id, game_id FROM game_platforms
                UNION
                SELECT p.platform_id, pg.game_id FROM products p
                JOIN product_games pg ON pg.product_id = p.id
            ) GROUP BY platform_id
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
        let (sql, arguments) = LibraryQuery.gamesSQL(filter)
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

        let platformIDs = try String.fetchAll(db, sql: """
            SELECT pid FROM (
                SELECT platform_id AS pid FROM game_platforms WHERE game_id = ?1
                UNION
                SELECT p.platform_id FROM products p JOIN product_games pg ON pg.product_id = p.id
                WHERE pg.game_id = ?1
            ) ORDER BY pid
            """, arguments: [id])

        let copyRows = try Row.fetchAll(db, sql: """
            SELECT p.id AS product_id, p.platform_id, p.format, p.kind, p.title,
                   p.edition, p.region, p.source, p.subscription, pg.position,
                   (SELECT COUNT(*) FROM product_games x WHERE x.product_id = p.id) AS member_count
            FROM product_games pg JOIN products p ON p.id = pg.product_id
            WHERE pg.game_id = ? ORDER BY p.id
            """, arguments: [id])
        let copies: [GameDetail.Copy] = try copyRows.map { r in
            let productID: Int64 = r["product_id"]
            let memberCount: Int = r["member_count"]
            var memberTitles: [String] = []
            var memberIDs: [Int64] = []
            // Only a compilation copy needs its full member list (PLAN §8 — the
            // all-or-nothing ownership names every affected game).
            if memberCount > 1 {
                let members = try Self.fetchCompilationMembers(productID, db)
                memberTitles = members.map(\.title)
                memberIDs = members.map(\.gameID)
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
                memberIDs: memberIDs
            )
        }

        let statusRaw: String? = g["status"]
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
            status: statusRaw.flatMap(PlayStatus.init(rawValue:)),
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
        try PlatformRecord.fetchAll(db, sql: """
            SELECT * FROM platforms WHERE id IN (
                SELECT platform_id FROM game_platforms
                UNION
                SELECT platform_id FROM products
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
