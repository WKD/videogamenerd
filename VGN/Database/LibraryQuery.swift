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
                   MIN(p.subscription IS NOT NULL)  AS sub_only,
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
            COALESCE(own.sub_only, 0)                        AS sub_only,
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
        appendScope(filter.scope, bounds: LengthShelf.bounds(for: filter.playPace),
                    style: filter.playStyle, into: &wheres, args: &args)
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
        _ scope: SidebarSelection, bounds: LengthBounds, style: PlayStyle,
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
        case .unlinked:
            // Games with no IGDB link (PLAN §5.1): no metadata / cover / time / traits,
            // and invisible to the `igdb_id` dedupe.
            wheres.append("g.igdb_id IS NULL")
        case .duel:
            wheres.append("g.played = 1 AND g.tier_id IS NOT NULL AND g.rank_key IS NULL")
        case let .length(shelf):
            appendLengthScope(shelf, bounds: bounds, style: style, into: &wheres, args: &args)
        case .unmeasured:
            wheres.append("\(lengthEstimateExpr(style: style)) IS NULL")
        case let .platform(slug):
            appendPlatformMembership(slug, into: &wheres, args: &args)
        }
    }

    /// WHERE clause for one "By Length" shelf: the **personal length** must exist and
    /// fall in the shelf's `[lower, upper)` seconds window (bounds derived from the
    /// pace; length derived from the play style).
    private static func appendLengthScope(
        _ shelf: LengthShelf, bounds: LengthBounds, style: PlayStyle,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        let expr = lengthEstimateExpr(style: style)
        let range = shelf.secondsRange(in: bounds)
        var conds = ["\(expr) IS NOT NULL"]
        if let lower = range.lower { conds.append("\(expr) >= ?"); args.append(lower) }
        if let upper = range.upper { conds.append("\(expr) < ?");  args.append(upper) }
        wheres.append(conds.count == 1 ? conds[0] : "(" + conds.joined(separator: " AND ") + ")")
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
        // Tier facet (OR within kind): selected tiers OR "Unrated" (played, no tier —
        // mirrors the sidebar "Unranked" list).
        var tierOrs: [String] = []
        if !filter.tierIDs.isEmpty {
            let ids = filter.tierIDs.sorted()
            tierOrs.append("g.tier_id IN (\(placeholders(ids.count)))")
            args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
        }
        if filter.includeUnrated { tierOrs.append("(g.played = 1 AND g.tier_id IS NULL)") }
        appendOR(tierOrs, into: &wheres)
        if !filter.decades.isEmpty {
            let ds = filter.decades.sorted()
            wheres.append("g.decade IN (\(placeholders(ds.count)))")
            args.append(contentsOf: ds.map { $0 as DatabaseValueConvertible })
        }
        // Completion facet (OR within kind): selected statuses OR "Not Played"
        // (played = 0) OR "No Status" (played but no completion status).
        var statusOrs: [String] = []
        if !filter.statuses.isEmpty {
            let ss = filter.statuses.map(\.rawValue).sorted()
            statusOrs.append("g.status IN (\(placeholders(ss.count)))")
            args.append(contentsOf: ss.map { $0 as DatabaseValueConvertible })
        }
        if filter.includeNotPlayed { statusOrs.append("g.played = 0") }
        if filter.includeNoStatus { statusOrs.append("(g.played = 1 AND g.status IS NULL)") }
        appendOR(statusOrs, into: &wheres)

        // Format / ownership facet (OR within kind): a game matches if it has ≥ 1
        // owned product in one of the formats (PLAN §4), OR "Not Owned" (no owned
        // product/copy at all — the sidebar "Owned" definition, so compilation-owned
        // games count as owned and are excluded by "Not Owned").
        var formatOrs: [String] = []
        if !filter.formats.isEmpty {
            let fs = filter.formats.map(\.rawValue).sorted()
            formatOrs.append("""
                EXISTS(SELECT 1 FROM product_games pg JOIN products p ON p.id = pg.product_id
                       WHERE pg.game_id = g.id AND p.format IN (\(placeholders(fs.count))))
                """)
            args.append(contentsOf: fs.map { $0 as DatabaseValueConvertible })
        }
        if filter.includeNotOwned {
            formatOrs.append("NOT EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)")
        }
        appendOR(formatOrs, into: &wheres)
        // "Owns multiple copies" — ≥ 2 owned products for the game (its own facet,
        // ANDed across kinds; owner request 2026-09-19).
        if filter.multipleCopies {
            wheres.append("(SELECT COUNT(*) FROM product_games pg5 WHERE pg5.game_id = g.id) >= 2")
        }
        // Format ▸ "PS Plus" — games whose **only** owned copies are subscription copies
        // (PLAN §13.3). Its own facet, ANDed across kinds (like Multiple Copies): the game
        // must be owned AND have no owned copy that is really owned (subscription IS NULL).
        // With Status ▸ Not Played this is the "finish before unsubscribing" list.
        if filter.includeSubscriptionOnly {
            wheres.append("""
                (EXISTS(SELECT 1 FROM product_games pg6 WHERE pg6.game_id = g.id)
                 AND NOT EXISTS(SELECT 1 FROM product_games pg7 JOIN products p7 ON p7.id = pg7.product_id
                                WHERE pg7.game_id = g.id AND p7.subscription IS NULL))
                """)
        }
        if !filter.genres.isEmpty {
            let gs = filter.genres.sorted()
            wheres.append("""
                EXISTS(SELECT 1 FROM game_genres gg JOIN genres ge ON ge.id = gg.genre_id
                       WHERE gg.game_id = g.id AND ge.name IN (\(placeholders(gs.count))))
                """)
            args.append(contentsOf: gs.map { $0 as DatabaseValueConvertible })
        }
        appendPlaytimeFacet(filter.playtimes, includeNoEstimate: filter.includeNoTimeEstimate,
                            style: filter.playStyle, into: &wheres, args: &args)
        if let match = ftsMatch(filter.searchText) {
            wheres.append("g.id IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?)")
            args.append(match)
        }
    }

    /// Combine one facet's OR-branches (its value set plus any "unset"/negative
    /// options — PLAN §8 "OR within a kind") into a single WHERE clause. Args for
    /// each branch are appended by the caller as the branch is built, in order.
    private static func appendOR(_ ors: [String], into wheres: inout [String]) {
        guard !ors.isEmpty else { return }
        wheres.append(ors.count == 1 ? ors[0] : "(" + ors.joined(separator: " OR ") + ")")
    }

    /// SQL for a game's **personal length** in seconds — how long the game is *for the
    /// owner* at a given play style (owner request 2026-09-19). It is the exact SQL
    /// mirror of ``PersonalLength/compute(normallyS:completelyS:style:r:)``: a linear
    /// blend of the *main* (`ttb_normally_s`) and *completionist* (`ttb_completely_s`)
    /// estimates, with a missing side inflated by ``PlayStyle/sidesRatio`` and a dirty
    /// `completely < normally` clamped up to `normally`. **Rushed (`ttb_hastily_s`) is
    /// never used** — a game with only that estimate is `NULL` here (Unmeasured). The
    /// style's `t` and the ratio `r` are inlined as decimal literals (app constants,
    /// never user input); `ROUND` + `CAST … AS INTEGER` makes the value match the Swift
    /// path to the second (no SQLite math-extension functions used).
    static func lengthEstimateExpr(style: PlayStyle, r: Double = PlayStyle.sidesRatio) -> String {
        let t = sqlLiteral(style.t)
        let rl = sqlLiteral(r)
        return "CAST(ROUND(CASE"
            + " WHEN g.ttb_normally_s IS NOT NULL AND g.ttb_completely_s IS NOT NULL"
            + " THEN g.ttb_normally_s + \(t) * (CASE WHEN g.ttb_completely_s < g.ttb_normally_s"
            + " THEN 0 ELSE g.ttb_completely_s - g.ttb_normally_s END)"
            + " WHEN g.ttb_normally_s IS NOT NULL"
            + " THEN g.ttb_normally_s * (1 + \(t) * (\(rl) - 1))"
            + " WHEN g.ttb_completely_s IS NOT NULL"
            + " THEN g.ttb_completely_s * (1 + \(t) * (\(rl) - 1)) / \(rl)"
            + " ELSE NULL END) AS INTEGER)"
    }

    /// The seconds a game is bucketed on for the playtime filter: effective playtime
    /// (manual over PSN), falling back to the owner's **personal length** (see
    /// ``lengthEstimateExpr(style:r:)``) for a game they have not played, so an unplayed
    /// game is banded by how long it is *for them* rather than dropped (PLAN §6.4/§8).
    /// The filter always prefers the owner's own playtime first. "No Estimate" (this
    /// expression `IS NULL`) means exactly "no time info to fetch" (a rushed-only game
    /// counts as No Estimate, since rushed is never used for length).
    static func playtimeBucketExpr(style: PlayStyle) -> String {
        "COALESCE(g.my_playtime_s, g.psn_playtime_s, \(lengthEstimateExpr(style: style)))"
    }

    /// One grouped pass computing the five "By Length" shelf counts plus the
    /// "Unmeasured" (no personal length) count for the sidebar (PLAN §8). The
    /// pace-derived bounds are passed as **arguments** (seconds), never literals, so
    /// changing the pace or style only re-runs this query. Personal length only — see
    /// ``lengthEstimateExpr(style:r:)``.
    static func lengthShelfCountsSQL(
        bounds: LengthBounds, style: PlayStyle
    ) -> (sql: String, arguments: StatementArguments) {
        var cols: [String] = []
        var args: [DatabaseValueConvertible] = []
        for shelf in LengthShelf.allCases {
            let range = shelf.secondsRange(in: bounds)
            var conds = ["est IS NOT NULL"]
            if let lower = range.lower { conds.append("est >= ?"); args.append(lower) }
            if let upper = range.upper { conds.append("est < ?");  args.append(upper) }
            cols.append("COALESCE(SUM(\(conds.joined(separator: " AND "))), 0) AS \(shelf.rawValue)")
        }
        cols.append("COALESCE(SUM(est IS NULL), 0) AS unmeasured")
        let sql = """
            SELECT \(cols.joined(separator: ",\n                   "))
            FROM (SELECT \(lengthEstimateExpr(style: style)) AS est FROM games g)
            """
        return (sql, StatementArguments(args))
    }

    /// Fetch the per-shelf + "Unmeasured" counts. Composed into the single sidebar
    /// observation alongside the scalar/per-platform counts (never a second one).
    static func fetchLengthShelfCounts(
        _ db: Database, bounds: LengthBounds, style: PlayStyle
    ) throws -> (shelves: [LengthShelf: Int], unmeasured: Int) {
        let (sql, arguments) = lengthShelfCountsSQL(bounds: bounds, style: style)
        let row = try Row.fetchOne(db, sql: sql, arguments: arguments)!
        var shelves: [LengthShelf: Int] = [:]
        for shelf in LengthShelf.allCases { shelves[shelf] = row[shelf.rawValue] }
        return (shelves, row["unmeasured"])
    }

    /// Count of games with no IGDB link (`igdb_id IS NULL`) — the sidebar "Unlinked"
    /// row (PLAN §5.1). Composed into the single sidebar-counts observation alongside
    /// the scalar/per-platform/length counts, never as a second observation.
    static func fetchUnlinkedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE igdb_id IS NULL") ?? 0
    }

    /// Locale-independent decimal literal for a `Double` app constant (Swift's own
    /// `Double` description; always carries a fractional part).
    private static func sqlLiteral(_ value: Double) -> String {
        let s = String(value)
        return s.contains(".") ? s : s + ".0"
    }

    /// OR-within-kind playtime filter: a game matches if its bucket value falls in
    /// any selected band, OR (when `includeNoEstimate`) it has no bucket value at all
    /// (no effective playtime and no IGDB estimate of any kind). Buckets are emitted
    /// in canonical (ascending) order so the SQL is deterministic.
    private static func appendPlaytimeFacet(
        _ buckets: Set<PlaytimeBucket>, includeNoEstimate: Bool, style: PlayStyle,
        into wheres: inout [String], args: inout [DatabaseValueConvertible]
    ) {
        guard !buckets.isEmpty || includeNoEstimate else { return }
        let expr = playtimeBucketExpr(style: style)
        var ors: [String] = []
        for bucket in PlaytimeBucket.allCases where buckets.contains(bucket) {
            var conds: [String] = ["\(expr) IS NOT NULL"]
            if let lower = bucket.lowerSeconds {
                conds.append("\(expr) >= ?"); args.append(lower)
            }
            if let upper = bucket.upperSeconds {
                conds.append("\(expr) < ?"); args.append(upper)
            }
            ors.append("(" + conds.joined(separator: " AND ") + ")")
        }
        if includeNoEstimate { ors.append("\(expr) IS NULL") }
        appendOR(ors, into: &wheres)
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
        case .length:
            // By the personal length (how long the game is for the owner), NULLs last.
            let expr = lengthEstimateExpr(style: filter.playStyle)
            terms = ["(\(expr) IS NULL)", "\(expr) \(dir)"]
        case .lastPlayed:
            // Most-recently-played first (importer-filled), NULLs (never played by an
            // importer) always last regardless of direction.
            terms = ["(g.last_played_at IS NULL)", "g.last_played_at \(dir)"]
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
            hasROM: row["has_rom"],
            ownedOnlyViaSubscription: row["sub_only"]
        )
    }
}
