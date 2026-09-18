import Foundation
import GRDB

/// Compiles a ``LibraryFilter`` into a single SQL query for the grid, and maps
/// result rows to the slim ``GameSummary`` (PLAN §8: filters combine AND across
/// kinds, OR within a kind; one SQL query; no N+1).
///
/// Search is a basic FTS5 prefix match for now (next wave deepens it).
enum LibraryQuery {
    /// The SELECT list every grid row needs (owned / compilation / platform ids
    /// resolved inline so the cell never does a follow-up fetch).
    private static let selectClause = """
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
            EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id) AS owned,
            EXISTS(SELECT 1 FROM product_games pg
                   JOIN products p ON p.id = pg.product_id
                   WHERE pg.game_id = g.id AND p.kind = 'compilation') AS is_comp,
            (SELECT group_concat(pid) FROM (
                SELECT platform_id AS pid FROM game_platforms WHERE game_id = g.id
                UNION
                SELECT p2.platform_id FROM products p2
                JOIN product_games pg2 ON pg2.product_id = p2.id
                WHERE pg2.game_id = g.id
             )) AS platform_ids
        FROM games g
        LEFT JOIN tiers t ON t.id = g.tier_id
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

    // MARK: - Scope

    private static func appendScope(
        _ scope: SidebarSelection,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        switch scope {
        case .all, .tierBoard, .theTop:
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

    /// Builds a prefix MATCH query: each whitespace token becomes a quoted
    /// prefix term, ANDed together. Returns nil for empty/blank input.
    static func ftsMatch(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")
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
            platformIDs: platformIDs,
            status: statusRaw.flatMap(PlayStatus.init(rawValue:))
        )
    }
}
