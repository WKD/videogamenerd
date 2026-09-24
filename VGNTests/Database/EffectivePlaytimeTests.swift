import Foundation
import Testing
import GRDB
@testable import VGN

/// v17 read precedence: manual, else MAX(PSN, Batocera), never summed. The one SQL fragment
/// (`LibraryQuery.effectivePlaytimeSQL`) and its Swift mirror (`EffectivePlaytime`) agree.
@Suite struct EffectivePlaytimeTests {

    @Test func swiftMirrorRules() {
        #expect(EffectivePlaytime.seconds(manual: 10, psn: 500, batocera: 900) == 10)
        #expect(EffectivePlaytime.seconds(manual: nil, psn: 500, batocera: 900) == 900)
        #expect(EffectivePlaytime.seconds(manual: nil, psn: 900, batocera: 500) == 900)
        #expect(EffectivePlaytime.seconds(manual: nil, psn: 500, batocera: nil) == 500)
        #expect(EffectivePlaytime.seconds(manual: nil, psn: nil, batocera: 500) == 500)
        #expect(EffectivePlaytime.seconds(manual: nil, psn: nil, batocera: nil) == nil)
        #expect(EffectivePlaytime.seconds(manual: 0, psn: 500, batocera: nil) == 0)
    }

    @Test func sqlMatchesSwiftForEveryCombination() async throws {
        let db = try AppDatabase.inMemory()
        let values: [Int?] = [nil, 0, 120, 3600, 90_000]
        let expected = try await db.dbWriter.write { db -> [Int64: Int?] in
            var expected: [Int64: Int?] = [:]
            for m in values { for p in values { for b in values {
                try db.execute(sql: """
                    INSERT INTO games (title, played, my_playtime_s, psn_playtime_s, batocera_playtime_s)
                    VALUES ('G', 1, ?, ?, ?)
                    """, arguments: [m, p, b])
                expected[db.lastInsertedRowID] = EffectivePlaytime.seconds(manual: m, psn: p, batocera: b)
            } } }
            return expected
        }
        let rows = try await db.dbWriter.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT g.id, \(LibraryQuery.effectivePlaytimeSQL()) AS e FROM games g")
        }
        #expect(rows.count == values.count * values.count * values.count)
        for r in rows {
            let id: Int64 = r["id"]
            let e: Int? = r["e"]
            #expect(e == expected[id]!, "game \(id)")
        }
        // The bare-column variant (exporter) is the same expression.
        let bare = try await db.dbWriter.read { db -> [Row] in
            try Row.fetchAll(db, sql: "SELECT id, \(LibraryQuery.effectivePlaytimeSQL(alias: nil)) AS e FROM games")
        }
        for r in bare { #expect((r["e"] as Int?) == expected[r["id"] as Int64]!) }
    }

    /// The detail model uses the same rule (inspector bar, The Top).
    @Test func gameDetailEffectiveUsesMax() async throws {
        let db = try AppDatabase.inMemory()
        let store = LibraryStore(db)
        let id = try await db.dbWriter.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO games (title, played, psn_playtime_s, batocera_playtime_s) VALUES ('G', 1, 3000, 11000)")
            return db.lastInsertedRowID
        }
        let detail = try #require(try await store.gameDetail(id: id))
        #expect(detail.psnPlaytimeS == 3000)
        #expect(detail.batoceraPlaytimeS == 11000)
        #expect(detail.effectivePlaytimeS == 11000)   // max, never 14000
    }

    /// Stats and the CSV export read through the same fragment: max, never summed.
    @Test func statsAndCSVUseMaxNeverSum() async throws {
        let store = try await TestDB.makeStore()
        let id = try await store.addGame(GameDraft(title: "Both Machines", platformIDs: ["snes"],
                                                   owned: true, played: true)).gameID
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE games SET psn_playtime_s = 3600, batocera_playtime_s = 7200 WHERE id = ?",
                           arguments: [id])
        }
        let report = try await LibraryStatsStore(store.database).report(scope: .all)
        #expect(report.totalPlaytimeSeconds == 7200)

        let csv = try await LibraryExporter(store.database).exportCSV()
        let header = LibraryExporter.csvHeader
        let line = try #require(csv.split(separator: "\n").map(String.init).first { $0.hasPrefix("Both Machines") })
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(fields[header.firstIndex(of: "my_playtime_hours")!] == "2.0")
        #expect(fields[header.firstIndex(of: "batocera_playtime_hours")!] == "2.0")
    }
}
