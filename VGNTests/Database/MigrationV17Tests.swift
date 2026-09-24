import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v17 (PLAN §7b "Scheduled 2026-09-25", §15): `games.batocera_playtime_s` plus the
/// explicit owner-requested one-shot move of the interim Batocera time out of `psn_playtime_s`.
@Suite struct MigrationV17Tests {

    @Test func freshDBHasNullableCheckedColumn() async throws {
        let db = try AppDatabase.inMemory()
        let value = try await db.dbWriter.write { db -> Int64? in
            try db.execute(sql: "INSERT INTO games (title) VALUES ('G')")
            return try Int64.fetchOne(db, sql: "SELECT batocera_playtime_s FROM games WHERE id = ?",
                                      arguments: [db.lastInsertedRowID])
        }
        #expect(value == nil)
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT INTO games (title, batocera_playtime_s) VALUES ('Bad', -1)")
            }
        }
    }

    /// The real chain up to v16 (W21-A's `games.holds_up`), i.e. the DB v17 upgrades in the field.
    private static func upToV16() -> DatabaseMigrator {
        var m = DatabaseMigrator()
        Migrations.registerV1(in: &m); Migrations.registerV2(in: &m); Migrations.registerV3(in: &m)
        Migrations.registerV4(in: &m); Migrations.registerV5(in: &m); Migrations.registerV6(in: &m)
        Migrations.registerV7(in: &m); Migrations.registerV8(in: &m); Migrations.registerV9(in: &m)
        Migrations.registerV10(in: &m); Migrations.registerV11(in: &m); Migrations.registerV12(in: &m)
        Migrations.registerV13(in: &m); Migrations.registerV14(in: &m); Migrations.registerV15(in: &m)
        Migrations.registerV16(in: &m)
        return m
    }

    private struct Times: Equatable {
        var mine: Int64?, psn: Int64?, batocera: Int64?
    }

    private static func times(_ db: Database) throws -> [Int64: Times] {
        var out: [Int64: Times] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, my_playtime_s, psn_playtime_s, batocera_playtime_s FROM games") {
            out[r["id"]] = Times(mine: r["my_playtime_s"], psn: r["psn_playtime_s"], batocera: r["batocera_playtime_s"])
        }
        return out
    }

    /// Seeds a v16-shaped library (the real chain) covering every tie combination, upgrades, and checks the move.
    @Test func upgradeFromV16MovesOnlyBatoceraOnlyTimesAndFillsFromCatalogue() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        var migrator = Self.upToV16()
        try migrator.migrate(queue)

        try await queue.write { db in
            for pid in ["snes", "ps4"] {
                try db.execute(sql: """
                    INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                    VALUES (?, ?, ?, 'X', 'X', 'console', 0)
                    """, arguments: [pid, pid, pid])
            }
            func game(_ id: Int64, mine: Int? = nil, psn: Int? = nil) throws {
                try db.execute(sql: "INSERT INTO games (id, title, played, my_playtime_s, psn_playtime_s) VALUES (?, ?, 1, ?, ?)",
                               arguments: [id, "Game \(id)", mine, psn])
            }
            func copy(_ gameID: Int64, source: String, platform: String, format: String) throws {
                try db.execute(sql: """
                    INSERT INTO products (kind, format, platform_id, source, external_id)
                    VALUES ('single', ?, ?, ?, ?)
                    """, arguments: [format, platform, source, "\(source)-\(gameID)"])
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id) VALUES (?, ?)",
                               arguments: [db.lastInsertedRowID, gameID])
            }
            func catalogue(_ gameID: Int64?, path: String, time: Int, source: String = "batocera") throws {
                try db.execute(sql: """
                    INSERT INTO rom_catalog (source, system, relative_path, name, game_time_s, promoted_game_id)
                    VALUES (?, 'snes', ?, ?, ?, ?)
                    """, arguments: [source, path, path, time, gameID])
            }
            // 1 Batocera-only via a ROM copy.
            try game(1, psn: 3600); try copy(1, source: "batocera", platform: "snes", format: "rom")
            // 2 Batocera-only via a promoted catalogue row (no copy) — moves; catalogue does not override.
            try game(2, psn: 1800); try catalogue(2, path: "two.zip", time: 2000)
            // 3 PSN-only copy — unchanged.
            try game(3, psn: 5000); try copy(3, source: "psn", platform: "ps4", format: "digital")
            // 4 Both: ROM copy + a matched PSN import row; catalogue fills Batocera with its MAX.
            try game(4, psn: 7000); try copy(4, source: "batocera", platform: "snes", format: "rom")
            try catalogue(4, path: "four-a.zip", time: 3000); try catalogue(4, path: "four-b.zip", time: 4000)
            try db.execute(sql: "INSERT INTO import_titles (source, external_id, name, matched_game_id) VALUES ('psn', 'np:4', 'Game 4', 4)")
            // 5 Manual time + Batocera-only — manual never touched, the interim value moves.
            try game(5, mine: 100, psn: 200); try copy(5, source: "batocera", platform: "snes", format: "rom")
            // 6 Catalogue with 0 s, no time at all — stays NULL.
            try game(6); try catalogue(6, path: "six.zip", time: 0)
            // 7 Unrelated game with a PSN time and no ties — unchanged; its v16 mark survives.
            try game(7, psn: 900)
            try db.execute(sql: "UPDATE games SET holds_up = 'holds_up' WHERE id = 7")
            // 8 Both via copies (ROM + PSN) — PSN kept, nothing to fill.
            try game(8, psn: 4200); try copy(8, source: "batocera", platform: "snes", format: "rom")
            try copy(8, source: "psn", platform: "ps4", format: "digital")
            // 9 Batocera tie + a promoted PS Plus Vault row — treated as PSN-tied, unchanged.
            try game(9, psn: 3000); try copy(9, source: "batocera", platform: "snes", format: "rom")
            try catalogue(9, path: "CUSA0009", time: 0, source: "psn")
            // 10 Promoted catalogue row, no interim time — filled from the catalogue.
            try game(10); try catalogue(10, path: "ten.zip", time: 5400)
            // An un-promoted catalogue row never matters.
            try catalogue(nil, path: "loose.zip", time: 99999)
        }

        Migrations.registerV17(in: &migrator)
        try migrator.migrate(queue)

        let after = try await queue.read { try Self.times($0) }
        #expect(after[1] == Times(mine: nil, psn: nil, batocera: 3600))
        #expect(after[2] == Times(mine: nil, psn: nil, batocera: 1800))
        #expect(after[3] == Times(mine: nil, psn: 5000, batocera: nil))
        #expect(after[4] == Times(mine: nil, psn: 7000, batocera: 4000))
        #expect(after[5] == Times(mine: 100, psn: nil, batocera: 200))
        #expect(after[6] == Times(mine: nil, psn: nil, batocera: nil))
        #expect(after[7] == Times(mine: nil, psn: 900, batocera: nil))
        #expect(after[8] == Times(mine: nil, psn: 4200, batocera: nil))
        #expect(after[9] == Times(mine: nil, psn: 3000, batocera: nil))
        #expect(after[10] == Times(mine: nil, psn: nil, batocera: 5400))

        // Idempotent semantics: re-running the data steps changes nothing more.
        try await queue.write { db in
            try db.execute(sql: Migrations.v17MoveSQL)
            try db.execute(sql: Migrations.v17CatalogueFillSQL)
        }
        let again = try await queue.read { try Self.times($0) }
        #expect(again == after)

        // FKs + integrity.
        let (fkViolations, integrity, hasColumn) = try await queue.read { db in
            (try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
             try String.fetchOne(db, sql: "PRAGMA integrity_check"),
             try db.columns(in: "games").contains { $0.name == "batocera_playtime_s" })
        }
        #expect(fkViolations == 0)
        #expect(integrity == "ok")
        #expect(hasColumn)
        let holdsUp = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT holds_up FROM games WHERE id = 7")
        }
        #expect(holdsUp == "holds_up")
        // The app's migrator registers v16 before v17.
        let order = AppDatabase.migrator.migrations
        #expect(order.firstIndex(of: "v16")! < order.firstIndex(of: "v17")!)
        #expect(order.last == "v17")
    }
}
