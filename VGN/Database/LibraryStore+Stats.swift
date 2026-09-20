import Foundation
import GRDB

/// The cheap library aggregates the sidebar stats popover shows (PLAN §6.4). A few
/// grouped queries — not a full stats view (that is a later milestone).
extension LibraryStore {
    /// One-shot library stats.
    func libraryStats() async throws -> LibraryStats {
        try await dbReader.read { db in try Self.fetchLibraryStats(db) }
    }

    /// Live library stats (the popover refreshes itself as the library changes).
    func libraryStatsObservation() -> AsyncValueObservation<LibraryStats> {
        ValueObservation.tracking { db in try Self.fetchLibraryStats(db) }.values(in: dbReader)
    }

    static func fetchLibraryStats(_ db: Database) throws -> LibraryStats {
        let head = try Row.fetchOne(db, sql: """
            SELECT
                COUNT(*) AS total,
                COALESCE(SUM(EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)), 0) AS owned,
                COALESCE(SUM(g.played), 0) AS played,
                COALESCE(SUM(g.played = 0 AND
                             EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)), 0) AS backlog,
                COALESCE(SUM(COALESCE(g.my_playtime_s, g.psn_playtime_s, 0)), 0) AS playtime
            FROM games g
            """)!

        let platformRows = try Row.fetchAll(db, sql: """
            SELECT platform_id AS pid, COUNT(DISTINCT game_id) AS n
            FROM (\(LibraryQuery.effectivePlatformsSQL))
            GROUP BY platform_id ORDER BY n DESC, pid LIMIT 5
            """)
        let byPlatform = platformRows.map {
            LibraryStats.PlatformCount(platformID: $0["pid"], count: $0["n"])
        }

        let tierRows = try Row.fetchAll(db, sql: """
            SELECT t.id AS tid, t.letter AS letter, COUNT(g.id) AS n
            FROM tiers t
            LEFT JOIN games g ON g.tier_id = t.id AND g.played = 1
            GROUP BY t.id ORDER BY t.sort, t.id
            """)
        let byTier = tierRows.map {
            LibraryStats.TierCount(tierID: $0["tid"], letter: $0["letter"], count: $0["n"])
        }

        return LibraryStats(
            total: head["total"], owned: head["owned"], played: head["played"],
            backlog: head["backlog"], totalPlaytimeSeconds: head["playtime"],
            byPlatform: byPlatform, byTier: byTier)
    }
}
