import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v13 (PLAN §16 "Send to the Vault" / §5.1 resume-after-cancel): three additive
/// `import_titles` columns — `vaulted` (default 0), `match_attempted_at` (nullable), `match_json`
/// (nullable). A fresh DB has them; an upgrade from v12 keeps every row and adds them.
@Suite struct MigrationV13Tests {

    private func insertTitle(_ db: Database, source: String, ext: String) throws {
        try db.execute(sql: """
            INSERT INTO import_titles (source, external_id, name, signals, ignored)
            VALUES (?, ?, ?, 'owned', 0)
            """, arguments: [source, ext, "Game \(ext)"])
    }

    @Test func freshDBHasV13ColumnsWithDefaults() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in try self.insertTitle(db, source: "gog", ext: "1") }
        let values = try await db.dbWriter.read { db -> (Int, Date?, String?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT vaulted, match_attempted_at, match_json FROM import_titles WHERE external_id = '1'
                """)!
            return (row["vaulted"], row["match_attempted_at"], row["match_json"])
        }
        #expect(values.0 == 0)
        #expect(values.1 == nil)
        #expect(values.2 == nil)
    }

    @Test func upgradeFromV12KeepsRowsAndAddsColumns() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV12 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV12)
        Migrations.registerV2(in: &upToV12)
        Migrations.registerV3(in: &upToV12)
        Migrations.registerV4(in: &upToV12)
        Migrations.registerV5(in: &upToV12)
        Migrations.registerV6(in: &upToV12)
        Migrations.registerV7(in: &upToV12)
        Migrations.registerV8(in: &upToV12)
        Migrations.registerV9(in: &upToV12)
        Migrations.registerV10(in: &upToV12)
        Migrations.registerV11(in: &upToV12)
        Migrations.registerV12(in: &upToV12)
        try upToV12.migrate(queue)

        try await queue.write { db in
            try self.insertTitle(db, source: "gog", ext: "1")
            try self.insertTitle(db, source: "psn", ext: "2")
        }
        let before = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_titles") ?? -1
        }

        var full = upToV12
        Migrations.registerV13(in: &full)
        try full.migrate(queue)

        let (count, vaultedZeros) = try await queue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_titles") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_titles WHERE vaulted = 0") ?? -1)
        }
        #expect(count == before)          // no rows lost
        #expect(vaultedZeros == before)   // every existing row defaults to not-vaulted
    }
}
