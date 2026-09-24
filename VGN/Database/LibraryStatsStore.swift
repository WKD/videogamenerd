import Foundation
import GRDB

/// The read-only data side of the Library Stats window (PLAN §6.4 — "a stats view:
/// total hours, by platform/decade/tier", extended to the full dashboard). A thin,
/// `Sendable` value over ``AppDatabase`` (the mirror of ``LibraryStore`` for stats),
/// computing one ``LibraryStatsReport`` in a **single read transaction** with plain
/// SQL aggregates — no N+1, fast at 2 000 games.
///
/// Derived scores are not stored (PLAN §7 "never stored"); the average-score
/// sections reuse the pure ``DerivedScore`` engine over the same ``RankSnapshot``
/// the ranking views load, so a stat and a chart can never disagree.
struct LibraryStatsStore: Sendable {
    let database: AppDatabase
    var dbReader: any DatabaseReader { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    /// One-shot report for a scope. `playStyle` sets the owner's **personal length** — the
    /// single source of truth the BY LENGTH shelves use — for planning hours like the
    /// backlog estimate (D4, owner request 2026-09-20).
    func report(scope: StatsScope, playStyle: PlayStyle = .default,
                referenceDate: Date = Date()) async throws -> LibraryStatsReport {
        try await dbReader.read { db in
            try Self.fetchReport(db, scope: scope, playStyle: playStyle, referenceDate: referenceDate)
        }
    }

    /// A cheap "something that feeds the stats changed" signal. The stats model
    /// observes this and re-queries the full report on each emission (treated as a
    /// change signal, not a payload — same pattern as the ranking views). It reads
    /// only aggregates over the tables the report draws from, so it is cheap and
    /// fires on any relevant write while GRDB's value dedup skips no-op churn.
    func changeSignal() -> AsyncValueObservation<String> {
        ValueObservation.tracking { db in try Self.fetchChangeSignal(db) }.values(in: dbReader)
    }

    static func fetchChangeSignal(_ db: Database) throws -> String {
        let row = try Row.fetchOne(db, sql: """
            SELECT
                (SELECT COUNT(*)                     FROM games)         AS g_n,
                (SELECT COALESCE(MAX(updated_at), '') FROM games)        AS g_upd,
                (SELECT COUNT(*)                     FROM products)      AS p_n,
                (SELECT COALESCE(MAX(updated_at), '') FROM products)     AS p_upd,
                (SELECT COUNT(*)                     FROM product_games) AS pg_n,
                (SELECT COUNT(*)                     FROM game_platforms) AS gp_n,
                (SELECT COUNT(*)                     FROM game_genres)   AS gg_n,
                (SELECT COUNT(*)                     FROM game_traits)   AS gt_n,
                (SELECT COUNT(*)                     FROM tiers)         AS t_n
            """)!
        let parts: [String] = ["g_n", "g_upd", "p_n", "p_upd", "pg_n", "gp_n", "gg_n", "gt_n", "t_n"]
            .map { String(describing: row[$0] ?? "") }
        return parts.joined(separator: "|")
    }

    // MARK: - Scope

    /// SQL predicate selecting the games in a scope (`g` is the `games` alias).
    private static func scopeClause(_ scope: StatsScope, _ alias: String = "g") -> String {
        switch scope {
        case .all:    return "1"
        case .owned:  return "EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = \(alias).id)"
        case .played: return "\(alias).played = 1"
        }
    }

    /// Effective playtime expression (manual over PSN — PLAN §6.4), 0 when neither.
    private static let effective = "COALESCE(g.my_playtime_s, g.psn_playtime_s, 0)"
    /// Effective playtime, NULL when neither side is set (for "has a value" tests).
    private static let effectiveOrNull = "COALESCE(g.my_playtime_s, g.psn_playtime_s)"

    // MARK: - Report

    static func fetchReport(_ db: Database, scope: StatsScope, playStyle: PlayStyle = .default,
                            referenceDate: Date) throws -> LibraryStatsReport {
        let s = scopeClause(scope)

        // 1 — Overview head + section-4 unknown-year, in one pass over games.
        let head = try Row.fetchOne(db, sql: """
            SELECT
                COUNT(*) AS total,
                COALESCE(SUM(EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)), 0) AS owned,
                COALESCE(SUM(g.played), 0) AS played,
                COALESCE(SUM(g.played = 0 AND
                    EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)), 0) AS backlog,
                COALESCE(SUM(g.played = 1 AND
                    NOT EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)), 0) AS playedNotOwned,
                COALESCE(SUM(\(effective)), 0) AS playtime,
                COALESCE(SUM(g.year IS NULL), 0) AS unknownYear
            FROM games g WHERE \(s)
            """)!

        // Compilations (products of kind compilation with a member in scope).
        let compilations = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM products p WHERE p.kind = 'compilation'
              AND EXISTS(SELECT 1 FROM product_games pg JOIN games g ON g.id = pg.game_id
                         WHERE pg.product_id = p.id AND \(s))
            """) ?? 0

        // Copies by format (products with a member in scope).
        let copiesByFormat = try Row.fetchAll(db, sql: """
            SELECT p.format AS fmt, COUNT(DISTINCT p.id) AS n FROM products p
            WHERE EXISTS(SELECT 1 FROM product_games pg JOIN games g ON g.id = pg.game_id
                        WHERE pg.product_id = p.id AND \(s))
            GROUP BY p.format
            """).compactMap { row -> LibraryStatsReport.FormatCount? in
                guard let fmt = ProductFormat(rawValue: row["fmt"]) else { return nil }
                return .init(format: fmt, count: row["n"])
            }
            .sorted { formatOrder($0.format) < formatOrder($1.format) }

        // 2/3 — Per-platform: total, owned/played split, effective playtime.
        // The union collapses each (platform, game) pair to one row, so COUNT(*) is
        // the distinct game count and SUM(playtime) never double-counts within a
        // platform.
        let platformRows = try Row.fetchAll(db, sql: """
            SELECT m.pid AS pid,
                   COUNT(*) AS total,
                   COALESCE(SUM(EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = m.gid)), 0) AS owned,
                   COALESCE(SUM(g.played = 1), 0) AS played,
                   COALESCE(SUM(\(effective)), 0) AS secs
            FROM (SELECT game_id AS gid, platform_id AS pid FROM (\(LibraryQuery.effectivePlatformsSQL))) m
            JOIN games g ON g.id = m.gid
            WHERE \(s)
            GROUP BY m.pid
            """)
        let platformBreakdown = platformRows
            .map { LibraryStatsReport.PlatformBreakdown(
                platformID: $0["pid"], total: $0["total"], owned: $0["owned"], played: $0["played"]) }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.platformID < $1.platformID }
        let playtimeByPlatform = platformRows
            .map { LibraryStatsReport.PlatformSeconds(platformID: $0["pid"], seconds: $0["secs"]) }
            .filter { $0.seconds > 0 }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.platformID < $1.platformID }

        // 4 — Games + playtime by decade (nil decade = unknown year).
        let decadeRows = try Row.fetchAll(db, sql: """
            SELECT g.decade AS decade, COUNT(*) AS n, COALESCE(SUM(\(effective)), 0) AS secs
            FROM games g WHERE \(s) GROUP BY g.decade
            """)
        let gamesByDecade = decadeRows
            .map { LibraryStatsReport.DecadeCount(decade: $0["decade"], count: $0["n"]) }
            .sorted(by: decadeSort(\.decade))
        let playtimeByDecade = decadeRows
            .map { LibraryStatsReport.DecadeSeconds(decade: $0["decade"], seconds: $0["secs"]) }
            .filter { $0.seconds > 0 }
            .sorted(by: decadeSort(\.decade))

        // 4 — Per-year histogram.
        let gamesByYear = try Row.fetchAll(db, sql: """
            SELECT g.year AS year, COUNT(*) AS n FROM games g
            WHERE \(s) AND g.year IS NOT NULL GROUP BY g.year ORDER BY g.year
            """).map { LibraryStatsReport.YearCount(year: $0["year"], count: $0["n"]) }

        // 5 — Tiers: played count + playtime per tier, every tier row present.
        let tierRows = try Row.fetchAll(db, sql: """
            SELECT t.id AS tid, t.letter AS letter, t.label AS label, t.color AS color, t.sort AS sort,
                   COALESCE(SUM(g.id IS NOT NULL), 0) AS n,
                   COALESCE(SUM(\(effective)), 0) AS secs
            FROM tiers t
            LEFT JOIN games g ON g.tier_id = t.id AND g.played = 1 AND \(s)
            GROUP BY t.id ORDER BY t.sort, t.id
            """)
        let tierBreakdown = tierRows.map {
            LibraryStatsReport.TierBreakdown(
                tierID: $0["tid"], letter: $0["letter"], label: $0["label"],
                colorHex: $0["color"], sort: $0["sort"], count: $0["n"])
        }
        let playtimeByTier = tierRows
            .map { LibraryStatsReport.TierSeconds(
                tierID: $0["tid"], letter: $0["letter"], colorHex: $0["color"], seconds: $0["secs"]) }
            .filter { $0.seconds > 0 }

        let unrankedPlayedCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM games g WHERE g.played = 1 AND g.tier_id IS NULL AND \(s)
            """) ?? 0

        // 2 — Top 10 most-played games.
        let topPlayed = try Row.fetchAll(db, sql: """
            SELECT g.id AS id, g.title AS title, \(effective) AS secs
            FROM games g WHERE \(s) AND \(effective) > 0
            ORDER BY secs DESC, g.sort_title LIMIT 10
            """).map { LibraryStatsReport.GamePlaytime(gameID: $0["id"], title: $0["title"], seconds: $0["secs"]) }

        // 2 — Me vs. average (games with both my/PSN playtime and an IGDB main est).
        let mvaRow = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(\(effectiveOrNull)), 0) AS mine,
                   COALESCE(SUM(g.ttb_normally_s), 0) AS avg,
                   COUNT(*) AS n
            FROM games g
            WHERE \(s) AND \(effectiveOrNull) IS NOT NULL AND g.ttb_normally_s IS NOT NULL
            """)!
        // "Backlog to beat" is a planning figure — time the owner would need — so it uses
        // the **personal length** at their play style (the BY LENGTH source of truth), not
        // the raw IGDB main story. A game with only a rushed estimate has no personal
        // length → it counts as *without an estimate* (D4). "Me vs. average" above keeps the
        // raw advertised `ttb_normally_s`, because that is what the comparison is against.
        let lengthExpr = LibraryQuery.lengthEstimateExpr(style: playStyle)
        let backlogEstRow = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(\(lengthExpr)), 0) AS est,
                   COALESCE(SUM(\(lengthExpr) IS NULL), 0) AS missing
            FROM games g
            WHERE \(s) AND g.played = 0
              AND EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)
            """)!
        let myHoursVsAverage = LibraryStatsReport.MeVsAverage(
            mineSeconds: mvaRow["mine"], averageSeconds: mvaRow["avg"], gameCount: mvaRow["n"],
            backlogEstimateSeconds: backlogEstRow["est"],
            backlogGamesMissingEstimate: backlogEstRow["missing"])

        // 6 — Games per genre.
        let gamesByGenre = try Row.fetchAll(db, sql: """
            SELECT ge.name AS genre, COUNT(DISTINCT gg.game_id) AS n
            FROM game_genres gg JOIN genres ge ON ge.id = gg.genre_id
            JOIN games g ON g.id = gg.game_id
            WHERE \(s) GROUP BY ge.id ORDER BY n DESC, ge.name
            """).map { LibraryStatsReport.GenreCount(genre: $0["genre"], count: $0["n"]) }

        // 7 — Status counts over played games.
        let st = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(g.status = 'playing'), 0)                     AS playing,
                   COALESCE(SUM(g.status = 'finished'), 0)                    AS finished,
                   COALESCE(SUM(g.status = 'completed'), 0)                   AS completed,
                   COALESCE(SUM(g.status = 'abandoned' AND g.revisit = 0), 0) AS abandoned,
                   COALESCE(SUM(g.status = 'abandoned' AND g.revisit = 1), 0) AS toRevisit,
                   COALESCE(SUM(g.status IS NULL), 0)                         AS noStatus,
                   COALESCE(SUM(g.holds_up = 'holds_up'), 0)                  AS huHoldsUp,
                   COALESCE(SUM(g.holds_up = 'of_its_time'), 0)               AS huOfItsTime,
                   COALESCE(SUM(g.holds_up = 'too_archaic'), 0)               AS huTooArchaic,
                   COALESCE(SUM(g.holds_up IS NULL), 0)                       AS huUnrated,
                   COUNT(*) AS played
            FROM games g WHERE g.played = 1 AND \(s)
            """)!
        let statusCounts = LibraryStatsReport.StatusCounts(
            playing: st["playing"], finished: st["finished"], completed: st["completed"],
            abandoned: st["abandoned"], toRevisit: st["toRevisit"], noStatus: st["noStatus"])
        // "Holds up today?" slice (PLAN §7b) — same pass over played games.
        let holdsUpCounts = LibraryStatsReport.HoldsUpCounts(
            holdsUp: st["huHoldsUp"], ofItsTime: st["huOfItsTime"],
            tooArchaic: st["huTooArchaic"], unrated: st["huUnrated"])
        let playedForStatus: Int = st["played"]
        let completionRate: Double? = playedForStatus > 0
            ? Double(statusCounts.finished + statusCounts.completed) / Double(playedForStatus)
            : nil

        // 8 — Games added per month, last 12 months.
        let monthRows = try Row.fetchAll(db, sql: """
            SELECT strftime('%Y-%m', g.added_at) AS ym, COUNT(*) AS n
            FROM games g WHERE \(s) AND g.added_at IS NOT NULL GROUP BY ym
            """)
        var monthCounts: [String: Int] = [:]
        for row in monthRows { if let ym = row["ym"] as String? { monthCounts[ym] = row["n"] } }
        let addedByMonth = lastTwelveMonths(reference: referenceDate, counts: monthCounts)

        // 5 — Derived-score sections (pure engine over the ranking snapshot).
        let scores = DerivedScore.scores(try RankingStore.loadSnapshot(db))
        let (averageScoreByPlatform, bestGameByPlatform) = try platformScores(db, scope: scope, scores: scores)
        let averageScoreByDecade = try decadeScores(db, scope: scope, scores: scores)
        let averageScoreByGenre = try genreScores(db, scope: scope, scores: scores)

        return LibraryStatsReport(
            scope: scope, referenceDate: referenceDate,
            totalGames: head["total"], ownedGames: head["owned"], playedGames: head["played"],
            backlogGames: head["backlog"], playedNotOwned: head["playedNotOwned"],
            compilations: compilations, copiesByFormat: copiesByFormat,
            totalPlaytimeSeconds: head["playtime"],
            playtimeByPlatform: playtimeByPlatform, playtimeByDecade: playtimeByDecade,
            playtimeByTier: playtimeByTier, topPlayed: topPlayed,
            myHoursVsAverage: myHoursVsAverage,
            platformBreakdown: platformBreakdown,
            gamesByDecade: gamesByDecade, gamesByYear: gamesByYear, unknownYearCount: head["unknownYear"],
            tierBreakdown: tierBreakdown, unrankedPlayedCount: unrankedPlayedCount,
            averageScoreByPlatform: averageScoreByPlatform,
            averageScoreByDecade: averageScoreByDecade,
            bestGameByPlatform: bestGameByPlatform,
            gamesByGenre: gamesByGenre, averageScoreByGenre: averageScoreByGenre,
            statusCounts: statusCounts, completionRate: completionRate,
            holdsUpCounts: holdsUpCounts,
            addedByMonth: addedByMonth)
    }

    // MARK: - Derived-score helpers (ranked games only)

    private static func platformScores(
        _ db: Database, scope: StatsScope, scores: [GameID: DerivedScoreValue]
    ) throws -> ([LibraryStatsReport.PlatformScore], [LibraryStatsReport.PlatformBestGame]) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.pid AS pid, m.gid AS gid, g.title AS title
            FROM (SELECT game_id AS gid, platform_id AS pid FROM (\(LibraryQuery.effectivePlatformsSQL))) m
            JOIN games g ON g.id = m.gid
            WHERE g.played = 1 AND g.tier_id IS NOT NULL AND \(scopeClause(scope))
            """)
        var sum: [String: Double] = [:], count: [String: Int] = [:]
        var best: [String: (gid: Int64, title: String, score: Double)] = [:]
        for row in rows {
            let pid: String = row["pid"], gid: Int64 = row["gid"], title: String = row["title"]
            guard let v = scores[gid]?.value else { continue }
            sum[pid, default: 0] += v
            count[pid, default: 0] += 1
            if let cur = best[pid] {
                if v > cur.score { best[pid] = (gid, title, v) }
            } else { best[pid] = (gid, title, v) }
        }
        let averages = count.map { pid, n in
            LibraryStatsReport.PlatformScore(platformID: pid, average: sum[pid]! / Double(n), n: n)
        }.sorted { $0.average != $1.average ? $0.average > $1.average : $0.platformID < $1.platformID }
        let bests = best.map { pid, b in
            LibraryStatsReport.PlatformBestGame(platformID: pid, gameID: b.gid, title: b.title, score: b.score)
        }.sorted { $0.score != $1.score ? $0.score > $1.score : $0.platformID < $1.platformID }
        return (averages, bests)
    }

    private static func decadeScores(
        _ db: Database, scope: StatsScope, scores: [GameID: DerivedScoreValue]
    ) throws -> [LibraryStatsReport.DecadeScore] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT g.id AS gid, g.decade AS decade FROM games g
            WHERE g.played = 1 AND g.tier_id IS NOT NULL AND \(scopeClause(scope))
            """)
        var sum: [Int?: Double] = [:], count: [Int?: Int] = [:]
        for row in rows {
            let gid: Int64 = row["gid"], decade: Int? = row["decade"]
            guard let v = scores[gid]?.value else { continue }
            sum[decade, default: 0] += v
            count[decade, default: 0] += 1
        }
        return count.map { decade, n in
            LibraryStatsReport.DecadeScore(decade: decade, average: sum[decade]! / Double(n), n: n)
        }.sorted(by: decadeSort(\.decade))
    }

    private static func genreScores(
        _ db: Database, scope: StatsScope, scores: [GameID: DerivedScoreValue]
    ) throws -> [LibraryStatsReport.GenreScore] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ge.name AS genre, gg.game_id AS gid
            FROM game_genres gg JOIN genres ge ON ge.id = gg.genre_id
            JOIN games g ON g.id = gg.game_id
            WHERE g.played = 1 AND g.tier_id IS NOT NULL AND \(scopeClause(scope))
            """)
        var sum: [String: Double] = [:], count: [String: Int] = [:]
        for row in rows {
            let genre: String = row["genre"], gid: Int64 = row["gid"]
            guard let v = scores[gid]?.value else { continue }
            sum[genre, default: 0] += v
            count[genre, default: 0] += 1
        }
        return count.compactMap { genre, n -> LibraryStatsReport.GenreScore? in
            guard n >= 3 else { return nil }   // only meaningful genres (PLAN brief: n ≥ 3)
            return LibraryStatsReport.GenreScore(genre: genre, average: sum[genre]! / Double(n), n: n)
        }.sorted { $0.average != $1.average ? $0.average > $1.average : $0.genre < $1.genre }
    }

    // MARK: - Small helpers

    private static func formatOrder(_ f: ProductFormat) -> Int {
        switch f { case .physical: return 0; case .digital: return 1; case .rom: return 2 }
    }

    /// Sort decade rows ascending with the "unknown" (nil) bucket last.
    private static func decadeSort<T>(_ key: @escaping (T) -> Int?) -> (T, T) -> Bool {
        { a, b in
            switch (key(a), key(b)) {
            case let (x?, y?): return x < y
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return false
            }
        }
    }

    /// The last twelve calendar months ending at `reference` (UTC, to match SQLite's
    /// `strftime` on the UTC `added_at`), filled from `counts` keyed "yyyy-MM".
    static func lastTwelveMonths(reference: Date, counts: [String: Int]) -> [LibraryStatsReport.MonthCount] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: reference)
        guard let end = cal.date(from: comps) else { return [] }
        var result: [LibraryStatsReport.MonthCount] = []
        for back in stride(from: 11, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .month, value: -back, to: end) else { continue }
            let c = cal.dateComponents([.year, .month], from: d)
            guard let y = c.year, let m = c.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            result.append(.init(year: y, month: m, count: counts[key] ?? 0))
        }
        return result
    }
}
