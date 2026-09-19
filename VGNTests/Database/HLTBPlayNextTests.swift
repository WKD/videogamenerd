import Foundation
import Testing
import GRDB
@testable import VGN

/// Play Next must see an HLTB-only estimate exactly like an IGDB one (PLAN §5.3/§7b):
/// the recommendation candidate loader reads `ttb_normally_s` / `ttb_completely_s`
/// straight from `games`, regardless of `ttb_source`, so a game whose only times came
/// from HowLongToBeat gets a time fit like any other.
@Suite struct HLTBPlayNextTests {

    @Test func hltbOnlyGameCarriesTheSameEstimateAsAnIGDBGame() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('pc', 'PC', 'PC', 'MS', 'Computer', 'computer', 1)
                """)
            // Owned, not played (a backlog candidate). One sourced from IGDB, one from
            // HLTB, identical times.
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_normally_s, ttb_completely_s, ttb_source)
                VALUES (1, 'From IGDB', 0, 36000, 72000, 'igdb')
                """)
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_normally_s, ttb_completely_s, ttb_source, hltb_id)
                VALUES (2, 'From HLTB', 0, 36000, 72000, 'hltb', 555)
                """)
            for gid in [1, 2] {
                try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES ('pc','single','digital','manual')")
                let pid = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                               arguments: [pid, gid])
            }
        }

        let candidates = try await db.dbWriter.read { db in
            try RecommendationStore.loadCandidates(db: db)
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let igdb = try #require(byID[1])
        let hltb = try #require(byID[2])

        // Both are picked up with the same estimate; the HLTB one is not special-cased.
        #expect(igdb.estimateSeconds == 36000)
        #expect(hltb.estimateSeconds == 36000)
        #expect(hltb.completionistSeconds == 72000)
        #expect(hltb.estimateSeconds == igdb.estimateSeconds)
        #expect(hltb.bracketEstimate(completionist: false) == igdb.bracketEstimate(completionist: false))
    }
}
