import Foundation
import GRDB

/// Compiles a ``LibraryFilter`` into a single SQL query for the grid, and maps
/// result rows to the slim ``GameSummary`` (PLAN §8: filters combine AND across
/// kinds, OR within a kind; one SQL query; no N+1).
///
/// Search is a basic FTS5 prefix match for now (next wave deepens it).
enum LibraryQuery {
    /// The grid's SELECT with its per-game facts (owned / compilation / ROM /
    /// platform ids) resolved through two **pre-aggregated CTEs** joined once,
    /// rather than four correlated subqueries evaluated per row (PLAN §9). At
    /// 1–2 k games this is the difference the perf pass targets: `own`/`plat` scan
    /// their bridge tables once and are joined, so the grid query drops from
    /// ~40–53 ms to a few ms in DEBUG.
    ///
    /// - `own(game_id, owned, is_comp, has_rom)` — one grouped pass over
    ///   `product_games ⋈ products`.
    /// - `plat(game_id, ids)` — one grouped pass over the platform sources
    ///   (`game_platforms` ∪ product platforms), `group_concat`ed.
    private static let selectClause = """
        WITH own AS (
            SELECT pg.game_id AS game_id,
                   1                                AS owned,
                   MAX(p.kind = 'compilation')      AS is_comp,
                   MAX(p.format = 'rom')            AS has_rom,
                   MAX(CASE WHEN p.kind = 'compilation' THEN p.id END)    AS comp_id,
                   MAX(CASE WHEN p.kind = 'compilation' THEN p.title END) AS comp_title
            FROM product_games pg JOIN products p ON p.id = pg.product_id
            GROUP BY pg.game_id
        ),
        plat AS (
            SELECT game_id, group_concat(pid) AS ids FROM (
                SELECT game_id, platform_id AS pid FROM game_platforms
                UNION
                SELECT pg.game_id, p.platform_id FROM products p
                JOIN product_games pg ON pg.product_id = p.id
            ) GROUP BY game_id
        )
        SELECT
            g.id                                             AS id,
            g.title                                          AS title,
            g.year                                           AS year,
            g.cover_file                                     AS cover_file,
            g.tier_id                                        AS tier_id,
            t.letter                                         AS tier_letter,
            t.color                                          AS tier_color,
            g.rank_key                                       AS rank_key,
            g.played                                         AS played,
            g.status                                         AS status,
            COALESCE(own.owned, 0)                           AS owned,
            COALESCE(own.is_comp, 0)                         AS is_comp,
            COALESCE(own.has_rom, 0)                         AS has_rom,
            own.comp_id                                      AS comp_id,
            own.comp_title                                   AS comp_title,
            plat.ids                                         AS platform_ids
        FROM games g
        LEFT JOIN tiers t ON t.id = g.tier_id
        LEFT JOIN own  ON own.game_id = g.id
        LEFT JOIN plat ON plat.game_id = g.id
        """

    /// Full grid query for `filter`.
    static func gamesSQL(_ filter: LibraryFilter) -> (sql: String, arguments: StatementArguments) {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []
        appendScope(filter.scope, into: &wheres, args: &args)
        appendFacets(filter, into: &wheres, args: &args)

        var sql = selectClause
        if !wheres.isEmpty { sql += "\nWHERE " + wheres.joined(separator: "\n  AND ") }
        sql += "\n" + orderBy(filter)
        return (sql, StatementArguments(args))
    }

    /// Grid query for the Tier Board (PLAN §7): every played, tiered game, ordered
    /// by tier then placed-first (fine rank), then the unplaced tail in queue
    /// order. Reuses the same slim `GameSummary` row shape.
    static func tierBoardSQL() -> (sql: String, arguments: StatementArguments) {
        let sql = selectClause + """

            WHERE g.tier_id IS NOT NULL AND g.played = 1
            ORDER BY t.sort, (g.rank_key IS NULL), g.rank_key, g.updated_at, g.id
            """
        return (sql, StatementArguments())
    }

    // MARK: - Scope

    private static func appendScope(
        _ scope: SidebarSelection,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        switch scope {
        case .all, .tierBoard, .theTop, .playNext:
            // Play Next renders its own recommendation view, not the grid.
            break
        case .owned:
            wheres.append("EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)")
        case .played:
            wheres.append("g.played = 1")
        case .backlog:
            wheres.append("g.played = 0")
            wheres.append("EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)")
        case .unranked:
            wheres.append("g.played = 1 AND g.tier_id IS NULL")
        case .duel:
            wheres.append("g.played = 1 AND g.tier_id IS NOT NULL AND g.rank_key IS NULL")
        case let .platform(slug):
            appendPlatformMembership(slug, into: &wheres, args: &args)
        }
    }

    private static func appendPlatformMembership(
        _ slug: String,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        wheres.append("""
            (EXISTS(SELECT 1 FROM game_platforms gp WHERE gp.game_id = g.id AND gp.platform_id = ?)
             OR EXISTS(SELECT 1 FROM products p3 JOIN product_games pg3 ON pg3.product_id = p3.id
                       WHERE pg3.game_id = g.id AND p3.platform_id = ?))
            """)
        args.append(slug)
        args.append(slug)
    }

    // MARK: - Facets (AND across kinds, OR within a kind)

    private static func appendFacets(
        _ filter: LibraryFilter,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        if let platform = filter.platform {
            appendPlatformMembership(platform, into: &wheres, args: &args)
        }
        if !filter.platforms.isEmpty {
            // OR within the kind: a game on any of the selected platforms matches.
            let slugs = filter.platforms.sorted()
            let placeholders = self.placeholders(slugs.count)
            wheres.append("""
                (EXISTS(SELECT 1 FROM game_platforms gp WHERE gp.game_id = g.id AND gp.platform_id IN (\(placeholders)))
                 OR EXISTS(SELECT 1 FROM products p4 JOIN product_games pg4 ON pg4.product_id = p4.id
                           WHERE pg4.game_id = g.id AND p4.platform_id IN (\(placeholders))))
                """)
            args.append(contentsOf: slugs.map { $0 as DatabaseValueConvertible })
            args.append(contentsOf: slugs.map { $0 as DatabaseValueConvertible })
        }
        if !filter.tierIDs.isEmpty {
            let ids = filter.tierIDs.sorted()
            wheres.append("g.tier_id IN (\(placeholders(ids.count)))")
            args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
        }
        if !filter.decades.isEmpty {
            let ds = filter.decades.sorted()
            wheres.append("g.decade IN (\(placeholders(ds.count)))")
            args.append(contentsOf: ds.map { $0 as DatabaseValueConvertible })
        }
        if !filter.statuses.isEmpty {
            let ss = filter.statuses.map(\.rawValue).sorted()
            wheres.append("g.status IN (\(placeholders(ss.count)))")
            args.append(contentsOf: ss.map { $0 as DatabaseValueConvertible })
        }
        if !filter.formats.isEmpty {
            // A game matches if it has ≥ 1 owned product in one of the formats
            // (PLAN §4 — physical / digital / rom).
            let fs = filter.formats.map(\.rawValue).sorted()
            wheres.append("""
                EXISTS(SELECT 1 FROM product_games pg JOIN products p ON p.id = pg.product_id
                       WHERE pg.game_id = g.id AND p.format IN (\(placeholders(fs.count))))
                """)
            args.append(contentsOf: fs.map { $0 as DatabaseValueConvertible })
        }
        if !filter.genres.isEmpty {
            let gs = filter.genres.sorted()
            wheres.append("""
                EXISTS(SELECT 1 FROM game_genres gg JOIN genres ge ON ge.id = gg.genre_id
                       WHERE gg.game_id = g.id AND ge.name IN (\(placeholders(gs.count))))
                """)
            args.append(contentsOf: gs.map { $0 as DatabaseValueConvertible })
        }
        if let match = ftsMatch(filter.searchText) {
            wheres.append("g.id IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?)")
            args.append(match)
        }
    }

    // MARK: - Ordering

    private static func orderBy(_ filter: LibraryFilter) -> String {
        let dir = filter.ascending ? "ASC" : "DESC"
        let terms: [String]
        switch filter.sort {
        case .title:
            terms = ["g.sort_title \(dir)"]
        case .year:
            terms = ["(g.year IS NULL)", "g.year \(dir)"]
        case .dateAdded:
            terms = ["g.added_at \(dir)"]
        case .tierRank:
            terms = ["(g.tier_id IS NULL)", "t.sort \(dir)",
                     "(g.rank_key IS NULL)", "g.rank_key \(dir)"]
        case .playtime:
            terms = ["(COALESCE(g.my_playtime_s, g.psn_playtime_s) IS NULL)",
                     "COALESCE(g.my_playtime_s, g.psn_playtime_s) \(dir)"]
        }
        return "ORDER BY " + (terms + ["g.sort_title ASC", "g.id ASC"]).joined(separator: ", ")
    }

    // MARK: - FTS

    /// Builds a safe multi-token prefix MATCH query (PLAN §8: "prefix match on
    /// title + alt titles, results as you type").
    ///
    /// Each whitespace-separated token becomes a **double-quoted string literal**
    /// with a trailing `*`, ANDed together — e.g. `met gear sol` →
    /// `"met"* "gear"* "sol"*`. Quoting makes the query immune to FTS5 syntax:
    /// inside a `"…"` string every character is literal except `"`, which is
    /// escaped by doubling, so punctuation in the user's input (`NieR:Automata`,
    /// `"`, `*`, `-`, `'`, `(`) can never produce a syntax error. Tokens that
    /// carry no letters/digits at all (e.g. a lone `-` or `*`) are dropped; if
    /// nothing tokenizable remains, returns nil (no text constraint).
    static func ftsMatch(_ text: String) -> String? {
        let terms = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { token in token.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }
            .map { token -> String in
                let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " ")
    }

    private static func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ", ")
    }

    // MARK: - Row mapping

    /// Map a grid result row to the slim ``GameSummary``.
    static func gameSummary(from row: Row) -> GameSummary {
        let statusRaw: String? = row["status"]
        let csv: String? = row["platform_ids"]
        let platformIDs = csv?.split(separator: ",").map(String.init) ?? []
        return GameSummary(
            id: row["id"],
            title: row["title"],
            year: row["year"],
            coverFile: row["cover_file"],
            tierID: row["tier_id"],
            tierLetter: row["tier_letter"],
            tierColorHex: row["tier_color"],
            rankKey: row["rank_key"],
            played: row["played"],
            owned: row["owned"],
            isCompilationMember: row["is_comp"],
            compilationTitle: row["comp_title"],
            compilationProductID: row["comp_id"],
            platformIDs: platformIDs,
            status: statusRaw.flatMap(PlayStatus.init(rawValue:)),
            hasROM: row["has_rom"]
        )
    }
}
