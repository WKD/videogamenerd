import Testing
import GRDB
@testable import VGN

/// Wave 0 smoke tests: prove the target links, GRDB is wired up, and the
/// SQLite build we get ships the features the plan depends on (FTS5).
struct SmokeTests {

    @Test func appModuleLinks() {
        // The app module is importable via @testable and its value types exist.
        #expect(SidebarSelection.all == .all)
        #expect(GameSummary.samples.isEmpty == false)
    }

    @Test func grdbOpensInMemoryDatabase() throws {
        let queue = try DatabaseQueue()
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()")
        }
        #expect(version != nil)
        #expect(version?.isEmpty == false)
    }

    @Test func sqliteHasFTS5() throws {
        // The whole search story (PLAN §4 games_fts) rests on FTS5 being
        // compiled into the SQLite that GRDB links. Fail loudly if it isn't.
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE VIRTUAL TABLE t USING fts5(x)")
            try db.execute(sql: "INSERT INTO t(x) VALUES ('broken sword baphomet')")
        }
        let hit = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM t WHERE t MATCH 'baphomet'")
        }
        #expect(hit == 1)
    }
}
