import Foundation
import Testing
import GRDB
@testable import VGN

#if DEBUG
/// Performance measurement for the grid query at scale (PLAN §9/§10 "any game
/// reachable in < 3 s at 1 000 games"). Seeds a synthetic library with
/// ``PerfSeeder`` and times the current CTE-based grid query against the previous
/// correlated-subquery form, printing both so the perf pass has before/after
/// numbers. Not a timing gate (asserts correctness + that the seeder works).
struct GridQueryPerfTests {

    /// The pre-optimisation grid SELECT (four correlated subqueries per row).
    private static let oldSelect = """
        SELECT
            g.id AS id, g.title AS title, g.year AS year, g.cover_file AS cover_file,
            g.tier_id AS tier_id, t.letter AS tier_letter, t.color AS tier_color,
            g.rank_key AS rank_key, g.played AS played, g.status AS status,
            EXISTS(SELECT 1 FROM product_games pg WHERE pg.game_id = g.id) AS owned,
            EXISTS(SELECT 1 FROM product_games pg JOIN products p ON p.id = pg.product_id
                   WHERE pg.game_id = g.id AND p.kind = 'compilation') AS is_comp,
            EXISTS(SELECT 1 FROM product_games pgr JOIN products pr ON pr.id = pgr.product_id
                   WHERE pgr.game_id = g.id AND pr.format = 'rom') AS has_rom,
            (SELECT group_concat(pid) FROM (
                SELECT platform_id AS pid FROM game_platforms WHERE game_id = g.id
                UNION
                SELECT p2.platform_id FROM products p2 JOIN product_games pg2 ON pg2.product_id = p2.id
                WHERE pg2.game_id = g.id)) AS platform_ids
        FROM games g LEFT JOIN tiers t ON t.id = g.tier_id
        ORDER BY g.sort_title ASC, g.id ASC
        """

    private func median(_ store: LibraryStore, sql: String, runs: Int = 7) async throws -> Duration {
        var samples: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<runs {
            let start = clock.now
            _ = try await store.database.dbWriter.read { db in
                try Row.fetchAll(db, sql: sql).map(LibraryQuery.gameSummary(from:))
            }
            samples.append(clock.now - start)
        }
        return samples.sorted()[runs / 2]
    }

    @Test func gridQueryScalesTo2000Games() async throws {
        // The full bundled platform set, so every synthetic platform slug resolves.
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let store = LibraryStore(db)
        await PerfSeeder.seed(into: store, count: 2000)

        let all = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        #expect(all.count == 2000)
        // The denormalised facts are present (no follow-up fetch per cell).
        #expect(all.contains { $0.owned })
        #expect(all.contains { $0.hasROM })
        #expect(all.allSatisfy { !$0.platformIDs.isEmpty })

        let (newSQL, _) = LibraryQuery.gamesSQL(LibraryFilter(scope: .all))
        let newMedian = try await median(store, sql: newSQL)
        let oldMedian = try await median(store, sql: Self.oldSelect)
        print("VGN perf: grid query @2000 — old(correlated) \(oldMedian) · new(CTE) \(newMedian)")
    }
}
#endif
