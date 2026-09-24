import Foundation
import GRDB

/// Compiles a ``LibraryFilter`` into a single SQL query for the grid, and maps
/// result rows to the slim ``GameSummary`` (PLAN §8: filters combine AND across
/// kinds, OR within a kind; one SQL query; no N+1).
///
/// Search is a basic FTS5 prefix match for now (next wave deepens it).
enum LibraryQuery {
    /// **The one effective-platform rule (PLAN §4).** The platforms a game SHOWS and is
    /// counted/filtered under, as `(game_id, platform_id)` rows — the single source every
    /// reader shares so pills, filters, counts, the inspector, stats and exports never drift:
    ///  - a game with ≥ 1 copy: the platforms of its copies (any product — single, compilation
    ///    membership, PS Plus claim) **∪** its `game_platforms` rows marked `played = 1` (a
    ///    platform the owner said they played on always shows);
    ///  - a game with **no** copy (played-not-owned): all its `game_platforms` rows.
    ///
    /// A non-played `game_platforms` row of an *owned* game is ignored on read — it is the
    /// echo of a copy, or a leftover of a deleted / re-platformed one. The row stays in the
    /// table untouched (nothing is ever pruned; owner decision 2026-09-20). Because a game
    /// always has either a copy or a `game_platforms` row, this never yields zero platforms
    /// for a game that has any.
    /// Perf note (W19): the "game with no copy" branch used to be a **correlated**
    /// `NOT EXISTS (… product_games WHERE game_id = gp.game_id)` evaluated per
    /// `game_platforms` row, which roughly doubled the 2 k-game grid query. It is now a
    /// single **anti-join** against one grouped pass over `product_games` (`has_prod`,
    /// covered by `product_games_game_idx`) — same set, no per-row subquery. `UNION`
    /// (not `UNION ALL`) still de-duplicates the (game, platform) pairs.
    static let effectivePlatformsSQL = """
        SELECT pg.game_id AS game_id, p.platform_id AS platform_id
        FROM products p JOIN product_games pg ON pg.product_id = p.id
        UNION
        SELECT gp.game_id AS game_id, gp.platform_id AS platform_id
        FROM game_platforms gp
        LEFT JOIN (SELECT game_id FROM product_games GROUP BY game_id) has_prod
               ON has_prod.game_id = gp.game_id
        WHERE gp.played = 1 OR has_prod.game_id IS NULL
        """

    /// The grid's SELECT with its per-game facts (owned / compilation / ROM /
    /// platform ids) resolved through two **pre-aggregated CTEs** joined once,
    /// rather than four correlated subqueries evaluated per row (PLAN §9). At
    /// 1–2 k games this is the difference the perf pass targets: `own`/`plat` scan
    /// their bridge tables once and are joined, so the grid query drops from
    /// ~40–53 ms to a few ms in DEBUG.
    ///
    /// - `own(game_id, owned, is_comp, has_rom, prod_plats, …)` — one grouped pass over
    ///   `product_games ⋈ products`; the product **platforms** are `group_concat`ed here
    ///   (`prod_plats`) in the SAME pass, so they cost nothing extra.
    /// - `gp_plat(game_id, ids)` — one grouped pass over `game_platforms` (the played rows,
    ///   plus every row of a game that has no copy — via an anti-join, not a per-row
    ///   subquery). The grid's `platform_ids` is `prod_plats ⧺ gp_plat.ids` (the Swift
    ///   `dedupedList` de-duplicates), so `product_games ⋈ products` is scanned **once**,
    ///   not twice (W19 perf: the effective-platform rule had `plat` re-scan it and dedup a
    ///   `UNION`, ~doubling the 2 k-game grid; this restores it near the old cost). The set
    ///   still equals ``effectivePlatformsSQL`` (which stays canonical for the filters), so
    ///   pills ≡ Platform filter ≡ sidebar counts.
    private static let selectClause = """
        WITH own AS (
            SELECT pg.game_id AS game_id,
                   1                                AS owned,
                   MAX(p.kind = 'compilation')      AS is_comp,
                   MAX(p.format = 'rom')            AS has_rom,
                   MIN(p.subscription IS NOT NULL)  AS sub_only,
                   group_concat(p.platform_id)      AS prod_plats,
                   MAX(CASE WHEN p.kind = 'compilation' THEN p.id END)    AS comp_id,
                   MAX(CASE WHEN p.kind = 'compilation' THEN p.title END) AS comp_title,
                   -- Per-format platform lists for the grid badges + tooltips (PLAN §8):
                   -- one grouped pass, group_concat skips NULLs so each list holds only the
                   -- matching copies' platforms. "Really owned" = subscription IS NULL; a
                   -- PS Plus claim is the sub_plats list, drawn as its own badge.
                   group_concat(CASE WHEN p.format = 'physical' AND p.subscription IS NULL THEN p.platform_id END) AS physical_plats,
                   group_concat(CASE WHEN p.format = 'digital'  AND p.subscription IS NULL THEN p.platform_id END) AS digital_plats,
                   group_concat(CASE WHEN p.format = 'rom'       AND p.subscription IS NULL THEN p.platform_id END) AS rom_plats,
                   group_concat(CASE WHEN p.subscription IS NOT NULL THEN p.platform_id END) AS sub_plats,
                   -- The "Change Copy Format" acting set (PLAN §13.3): non-subscription,
                   -- single-kind copies. count = 1 ⇒ that copy's format is reformat-able;
                   -- count ≥ 2 ⇒ ambiguous (skipped, banner footer).
                   SUM(CASE WHEN p.subscription IS NULL AND p.kind = 'single' THEN 1 ELSE 0 END) AS changeable_count,
                   MAX(CASE WHEN p.subscription IS NULL AND p.kind = 'single' THEN p.format END) AS changeable_format
            FROM product_games pg JOIN products p ON p.id = pg.product_id
            GROUP BY pg.game_id
        ),
        gp_plat AS (
            -- Only the game_platforms contribution to the effective platforms: the played
            -- rows, plus every row of a game with no copy (anti-join on has_prod). The
            -- product platforms come from `own.prod_plats`, so this never touches products.
            SELECT gp.game_id AS game_id, group_concat(gp.platform_id) AS ids
            FROM game_platforms gp
            LEFT JOIN (SELECT game_id FROM product_games GROUP BY game_id) has_prod
                   ON has_prod.game_id = gp.game_id
            WHERE gp.played = 1 OR has_prod.game_id IS NULL
            GROUP BY gp.game_id
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
            g.revisit                                        AS revisit,
            g.holds_up                                       AS holds_up,
            COALESCE(own.owned, 0)                           AS owned,
            COALESCE(own.is_comp, 0)                         AS is_comp,
            COALESCE(own.has_rom, 0)                         AS has_rom,
            COALESCE(own.sub_only, 0)                        AS sub_only,
            own.comp_id                                      AS comp_id,
            own.comp_title                                   AS comp_title,
            own.physical_plats                               AS physical_plats,
            own.digital_plats                                AS digital_plats,
            own.rom_plats                                    AS rom_plats,
            own.sub_plats                                    AS sub_plats,
            COALESCE(own.changeable_count, 0)                AS changeable_count,
            own.changeable_format                            AS changeable_format,
            -- Effective platforms = product platforms ⧺ game_platforms contribution; the
            -- Swift `dedupedList` de-duplicates and keeps first-seen order (products first).
            CASE
                WHEN own.prod_plats IS NOT NULL AND gp_plat.ids IS NOT NULL
                     THEN own.prod_plats || ',' || gp_plat.ids
                ELSE COALESCE(own.prod_plats, gp_plat.ids)
            END                                              AS platform_ids
        FROM games g
        LEFT JOIN tiers t ON t.id = g.tier_id
        LEFT JOIN own     ON own.game_id = g.id
        LEFT JOIN gp_plat ON gp_plat.game_id = g.id
        """

    /// Full grid query for `filter`.
    ///
    /// `restrictToIDs` scopes the result to a pre-computed id set — used by the
    /// ``SidebarSelection/bundlesToExpand`` smart list, whose candidate rule is a Swift title
    /// heuristic SQL can't express cheaply (PLAN §5.1): the caller computes the ids in Swift
    /// (``LibraryStore/fetchBundleExpansionCandidateIDs(_:)``) inside the same DB read, so the
    /// grid still updates live and the facets/sort keep working. An empty set matches nothing.
    static func gamesSQL(
        _ filter: LibraryFilter, restrictToIDs: [Int64]? = nil
    ) -> (sql: String, arguments: StatementArguments) {
        var wheres: [String] = []
        var args: [DatabaseValueConvertible] = []
        appendScope(filter.scope, bounds: LengthShelf.bounds(for: filter.playPace),
                    style: filter.playStyle, into: &wheres, args: &args)
        appendFacets(filter, into: &wheres, args: &args)
        if let ids = restrictToIDs {
            if ids.isEmpty {
                wheres.append("0")
            } else {
                wheres.append("g.id IN (\(placeholders(ids.count)))")
                args.append(contentsOf: ids.map { $0 as DatabaseValueConvertible })
            }
        }

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
        case .bundlesToExpand:
            // The candidate rule is a Swift title heuristic (``looksLikeBundleTitle``), so no
            // SQL constraint is added here: the caller passes the pre-computed id set via
            // `restrictToIDs` (see ``LibraryStore/fetchGames(_:_:)``). Reached with no restrict
            // set only in the preview/in-memory path, where the evaluator scopes it.
            break
        case .dlcAndExpansions:
            // Pure cached-type predicate (no request), like the bundle cached-type check (PLAN §5.1).
            wheres.append(dlcAndExpansionsPredicate())
        case .sameGameTwoEntries:
            wheres.append(sameGameTwoEntriesPredicate())
        case .duel:
            wheres.append("g.played = 1 AND g.tier_id IS NOT NULL AND g.rank_key IS NULL")
        case let .length(shelf):
            appendLengthScope(shelf, bounds: bounds, style: style, into: &wheres, args: &args)
        case .unmeasured:
            wheres.append("\(lengthEstimateExpr(style: style)) IS NULL")
        case .vault:
            // The Vault is a separate shelf that never routes to the library grid
            // (PLAN §15). Should a query ever reach here, match nothing rather than the library.
            wheres.append("0")
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
            EXISTS(SELECT 1 FROM (\(effectivePlatformsSQL)) ep
                   WHERE ep.game_id = g.id AND ep.platform_id = ?)
            """)
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
                EXISTS(SELECT 1 FROM (\(effectivePlatformsSQL)) ep
                       WHERE ep.game_id = g.id AND ep.platform_id IN (\(placeholders)))
                """)
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
        // Abandoned and To Revisit are disjoint here even though both are 'abandoned' in
        // SQL: ONE fragment `(status = ? AND revisit = ?)` per status distinguishes them by
        // the flag (revisit=0 vs 1), and keeps the in-memory evaluator (which compares the
        // mapped PlayStatus) exactly equivalent.
        var statusOrs: [String] = []
        if !filter.statuses.isEmpty {
            for status in PlayStatus.allCases where filter.statuses.contains(status) {
                statusOrs.append("(g.status = ? AND g.revisit = ?)")
                args.append(status.dbStatus as DatabaseValueConvertible)
                args.append(status.dbRevisit as DatabaseValueConvertible)
            }
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
        // "Duplicate Copies" — ≥ 2 really-owned copies (subscription IS NULL) sharing the SAME
        // platform AND format, e.g. two physical PS3 discs (owner request 2026-09-20). Each
        // product counts once; a compilation copy counts as a copy of each member (its
        // product_games row). Narrower than Multiple Copies; ANDs across kinds.
        if filter.duplicateCopies {
            wheres.append("""
                EXISTS(SELECT 1 FROM product_games pg8 JOIN products p8 ON p8.id = pg8.product_id
                       WHERE pg8.game_id = g.id AND p8.subscription IS NULL
                       GROUP BY p8.platform_id, p8.format HAVING COUNT(*) >= 2)
                """)
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
        // Playtime ▸ "Suspicious Estimate" — its own facet, ANDed across kinds (PLAN §5.3).
        if filter.includeSuspiciousEstimate {
            wheres.append(suspiciousEstimatePredicate())
        }
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
        let ratio = sqlLiteral(EstimateSanity.completionistRatio)
        // A flagged (suspicious & not hltb-sourced & not dismissed) game with a
        // completionist ≥ 4× main has its completionist ignored for planning (PLAN §5.3,
        // D5 — the SQL mirror of ``EstimateSanity/lengthInputs``): it falls back to
        // `main × r`, so the blend equals the main-only estimate. The **main**-implausible
        // cases (`rushed > main`, `main > completionist`) and a lone completionist fall
        // through to the normal branches, where the `completely < normally` clamp already
        // collapses a dirty completionist to the main story. `hltb`/dismissed games skip
        // the guard entirely.
        let guardSQL = suspiciousLengthGuardSQL()
        return "CAST(ROUND(CASE"
            + " WHEN \(guardSQL) AND g.ttb_normally_s IS NOT NULL AND g.ttb_completely_s IS NOT NULL"
            + " AND g.ttb_completely_s >= \(ratio) * g.ttb_normally_s"
            + " THEN g.ttb_normally_s + \(t) * (ROUND(g.ttb_normally_s * \(rl)) - g.ttb_normally_s)"
            + " WHEN g.ttb_normally_s IS NOT NULL AND g.ttb_completely_s IS NOT NULL"
            + " THEN g.ttb_normally_s + \(t) * (CASE WHEN g.ttb_completely_s < g.ttb_normally_s"
            + " THEN 0 ELSE g.ttb_completely_s - g.ttb_normally_s END)"
            + " WHEN g.ttb_normally_s IS NOT NULL"
            + " THEN g.ttb_normally_s * (1 + \(t) * (\(rl) - 1))"
            + " WHEN g.ttb_completely_s IS NOT NULL"
            + " THEN g.ttb_completely_s * (1 + \(t) * (\(rl) - 1)) / \(rl)"
            + " ELSE NULL END) AS INTEGER)"
    }

    // MARK: - Suspicious estimates (PLAN §5.3)

    /// SQL that yields the game ids the owner dismissed as "Estimate Looks Right"
    /// (persisted as a JSON array in `app_state`, mirroring `reconcile.notBundle`). A
    /// missing row decodes to the empty array, so nothing is excluded. Referencing
    /// `app_state` makes every query that uses the length expression / the suspicious
    /// facet re-run when a game is dismissed or flagged again (live, no timer).
    private static func dismissedEstimateSubquery() -> String {
        let key = sqlStringLiteral(LibraryStore.estimateLooksRightStateKey)
        return "SELECT value FROM json_each(COALESCE((SELECT json FROM app_state WHERE key = \(key)), '[]'))"
    }

    /// The guard shared by the length-expression fallback: a game is eligible to be
    /// treated as flagged only when its times are **not** from HowLongToBeat (the
    /// reference) and it was **not** dismissed.
    private static func suspiciousLengthGuardSQL() -> String {
        "(g.ttb_source IS NULL OR g.ttb_source <> 'hltb') AND g.id NOT IN (\(dismissedEstimateSubquery()))"
    }

    /// The **one** SQL mirror of ``EstimateSanity/isFlagged`` (D1): true for a game whose
    /// stored times are suspicious *and* that is neither hltb-sourced nor dismissed. Built
    /// from the same thresholds as the Swift rule, and proven to agree with it
    /// (`EstimateSanityTests`). A comparison against a NULL time is never true, exactly as
    /// the Swift rule only compares present values.
    static func suspiciousEstimatePredicate() -> String {
        let ratio = sqlLiteral(EstimateSanity.completionistRatio)
        let frac = sqlLiteral(EstimateSanity.rushedFraction)
        let core = [
            "g.ttb_hastily_s > g.ttb_normally_s",
            "g.ttb_normally_s > g.ttb_completely_s",
            "g.ttb_completely_s >= \(ratio) * g.ttb_normally_s",
            "g.ttb_hastily_s < \(frac) * g.ttb_normally_s",
            "(g.ttb_normally_s IS NULL AND g.ttb_completely_s IS NOT NULL)",
        ].joined(separator: " OR ")
        return "(\(suspiciousLengthGuardSQL()) AND (\(core)))"
    }

    /// A single-quoted SQL string literal for an app constant (no user input).
    private static func sqlStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
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

    // MARK: - "What counts as a game" review lists (PLAN §5.1)

    /// The cached IGDB `game_type` for `g` (else the legacy `category`), read from the game's
    /// own `catalog_cache` blob — the same zero-request join the bundle candidate rule uses.
    private static func cachedTypeExpr() -> String {
        "COALESCE(json_extract(cc.json, '$.game_type'), json_extract(cc.json, '$.category'))"
    }

    /// PLAN §5.1 "DLC & Expansions": a game whose own cached IGDB type is dlc_addon (1),
    /// expansion (2), mod (5), season (7), pack (13) or update (14) — NOT standalone_expansion (4)
    /// or episode (6), which are games in their own right.
    static func dlcAndExpansionsPredicate() -> String {
        """
        EXISTS(SELECT 1 FROM catalog_cache cc WHERE cc.igdb_id = g.igdb_id
               AND \(cachedTypeExpr()) IN (1, 2, 5, 7, 13, 14))
        """
    }

    /// PLAN §5.1 "Same Game, Two Entries": a game that is an IGDB **port** (game_type 11) whose
    /// `parent_game` or `version_parent` IGDB id is **also** a library game — the pairs the owner
    /// may want to merge (e.g. a 2020 port next to the 2007 original).
    static func sameGameTwoEntriesPredicate() -> String {
        """
        EXISTS(SELECT 1 FROM catalog_cache cc WHERE cc.igdb_id = g.igdb_id
               AND \(cachedTypeExpr()) = 11
               AND (json_extract(cc.json, '$.parent_game')
                        IN (SELECT igdb_id FROM games WHERE igdb_id IS NOT NULL AND igdb_id <> g.igdb_id)
                    OR json_extract(cc.json, '$.version_parent')
                        IN (SELECT igdb_id FROM games WHERE igdb_id IS NOT NULL AND igdb_id <> g.igdb_id)))
        """
    }

    /// Sidebar count for the "DLC & Expansions" row (composed into the single counts observation).
    static func fetchDLCAndExpansionsCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games g WHERE \(dlcAndExpansionsPredicate())") ?? 0
    }

    /// Sidebar count for the "Same Game, Two Entries" row.
    static func fetchSameGameTwoEntriesCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games g WHERE \(sameGameTwoEntriesPredicate())") ?? 0
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

    /// Map a grid result row to the slim ``GameSummary``. Reads the per-format facts with
    /// optional subscripts so a query that omits them (e.g. the perf baseline) still maps.
    static func gameSummary(from row: Row) -> GameSummary {
        let statusRaw: String? = row["status"]
        // The revisit flag turns a stored 'abandoned' into the model's `.toRevisit` — the
        // one place a grid row's raw status becomes a PlayStatus (v15).
        let revisit = (row["revisit"] as Int64?) == 1
        let platformIDs = dedupedList(row["platform_ids"])
        let changeableCount: Int = row["changeable_count"] ?? 0
        let changeableFormat: String? = row["changeable_format"]
        let singleCopyFormat = changeableCount == 1 ? changeableFormat.flatMap(ProductFormat.init(rawValue:)) : nil
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
            status: PlayStatus.from(dbStatus: statusRaw, revisit: revisit),
            holdsUp: HoldsUp(dbValue: row["holds_up"]),
            hasROM: row["has_rom"],
            ownedOnlyViaSubscription: row["sub_only"],
            physicalPlatformIDs: dedupedList(row["physical_plats"]),
            digitalPlatformIDs: dedupedList(row["digital_plats"]),
            romPlatformIDs: dedupedList(row["rom_plats"]),
            subscriptionPlatformIDs: dedupedList(row["sub_plats"]),
            singleCopyFormat: singleCopyFormat,
            hasSeveralChangeableCopies: changeableCount >= 2
        )
    }

    /// Split a `group_concat` CSV into a deduped list preserving first-seen order (a game
    /// with two physical copies on the same platform names the platform once).
    private static func dedupedList(_ csv: String?) -> [String] {
        guard let csv, !csv.isEmpty else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for piece in csv.split(separator: ",") {
            let s = String(piece)
            if seen.insert(s).inserted { out.append(s) }
        }
        return out
    }
}
