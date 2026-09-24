import Foundation
import Testing
import GRDB
@testable import VGN

/// Wave 21 lane B, D1 — Main-Story-only games are measured.
///  - the **write** rule through `applyHLTBTimes` / `replaceHLTBTimes`;
///  - the **read** rule for rows written before it (PLAN §4 inv. 5 — nothing rewritten):
///    an `hltb` row with only a rushed time uses it as the main in the ONE length expression
///    and its Swift mirror; IGDB rushed-only rows stay Unmeasured. SQL ≡ Swift parity, the
///    Akira-shaped row lands in One Evening, not Unmeasured / No Estimate / Suspicious.
@Suite struct HLTBMainStoryReadRuleTests {

    private let h = 3600

    /// (id, source, rushed, main, completionist)
    private typealias Row5 = (Int64, String?, Int?, Int?, Int?)

    private var rows: [Row5] {
        [
            (1, "hltb", 8070, nil, nil),          // Akira, pre-wave-21 write
            (2, "igdb", 5 * h, nil, nil),         // IGDB rushed-only → Unmeasured
            (3, nil, 5 * h, nil, nil),            // no source, rushed-only → Unmeasured
            (4, "hltb", 5 * h, nil, 20 * h),      // hltb rushed + completionist
            (5, "hltb", 5 * h, 10 * h, 12 * h),   // full hltb
            (6, "hltb", nil, nil, 30 * h),        // hltb completionist only
            (7, "igdb", 2 * h, 10 * h, 50 * h),   // igdb, suspicious completionist (guard)
            (8, "hltb", 2 * h, nil, 50 * h),      // hltb rushed + huge completionist (hltb skips guard)
            (9, "hltb", 8070, 8070, nil),         // Akira, wave-21 write
            (10, "igdb", nil, 12 * h, nil),       // igdb main only
        ]
    }

    private func seeded() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        let rows = self.rows
        try await db.dbWriter.write { db in
            for (id, source, r, m, c) in rows {
                try db.execute(sql: """
                    INSERT INTO games (id, title, played, ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                    VALUES (?, ?, 1, ?, ?, ?, ?)
                    """, arguments: [id, "g\(id)", r, m, c, source])
            }
        }
        return db
    }

    @Test(.timeLimit(.minutes(1)))
    func lengthExpressionMatchesTheSwiftMirrorForEveryStyle() async throws {
        let db = try await seeded()
        for style in PlayStyle.allCases {
            let expr = LibraryQuery.lengthEstimateExpr(style: style)
            let sql: [Int64: Int?] = try await db.dbWriter.read { db in
                var out: [Int64: Int?] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, \(expr) AS est FROM games g") {
                    out[row["id"]] = row["est"]
                }
                return out
            }
            for (id, source, r, m, c) in rows {
                let inputs = EstimateSanity.lengthInputs(rushed: r, main: m, completionist: c,
                                                         sourceIsHLTB: source == "hltb", dismissed: false)
                let swift = PersonalLength.compute(normallyS: inputs.main, completelyS: inputs.completionist,
                                                   style: style)?.seconds
                #expect((sql[id] ?? nil) == swift, "id \(id) \(style): SQL \(String(describing: sql[id] ?? nil)) vs Swift \(String(describing: swift))")
            }
            // The read rule itself.
            #expect((sql[1] ?? nil) != nil, "Akira (hltb, rushed only) is measured at \(style)")
            #expect((sql[2] ?? nil) == nil, "igdb rushed-only stays unmeasured at \(style)")
            #expect((sql[3] ?? nil) == nil, "sourceless rushed-only stays unmeasured at \(style)")
            #expect((sql[1] ?? nil) == (sql[9] ?? nil), "old and new Akira rows read the same at \(style)")
        }
    }

    @Test func effectiveMainMirrorsTheSQLFragment() async throws {
        let db = try await seeded()
        let sql: [Int64: Int?] = try await db.dbWriter.read { db in
            var out: [Int64: Int?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, \(LibraryQuery.effectiveMainSQL) AS m FROM games g") {
                out[row["id"]] = row["m"]
            }
            return out
        }
        for (id, source, r, m, _) in rows {
            #expect((sql[id] ?? nil) == EstimateSanity.effectiveMain(rushed: r, main: m, sourceIsHLTB: source == "hltb"),
                    "id \(id)")
        }
        #expect(EstimateSanity.isHLTBMainStoryOnly(rushed: 8070, main: nil, sourceIsHLTB: true))
        #expect(EstimateSanity.isHLTBMainStoryOnly(rushed: 8070, main: 8070, sourceIsHLTB: true))
        #expect(!EstimateSanity.isHLTBMainStoryOnly(rushed: 8070, main: nil, sourceIsHLTB: false))
        #expect(!EstimateSanity.isHLTBMainStoryOnly(rushed: 5 * h, main: 10 * h, sourceIsHLTB: true))
    }

    @Test func suspiciousPredicateStillMatchesTheSwiftRuleAndAkiraIsNotFlagged() async throws {
        let db = try await seeded()
        let flagged: Set<Int64> = try await db.dbWriter.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM games g WHERE \(LibraryQuery.suspiciousEstimatePredicate())"))
        }
        for (id, source, r, m, c) in rows {
            let swift = EstimateSanity.isFlagged(rushed: r, main: m, completionist: c,
                                                 sourceIsHLTB: source == "hltb", dismissed: false)
            #expect(flagged.contains(id) == swift, "id \(id)")
        }
        #expect(!flagged.contains(1) && !flagged.contains(9))
        #expect(flagged.contains(7))
    }

    // MARK: - Shelves / Unmeasured / No Estimate

    @Test(.timeLimit(.minutes(1)))
    func akiraSitsInOneEveningNotUnmeasuredNorNoEstimate() async throws {
        let store = LibraryStore(try await seeded())
        func ids(_ filter: LibraryFilter) async throws -> Set<Int64> {
            Set(try await store.gamesOnce(filter: filter).map(\.id))
        }
        let evening = try await ids(LibraryFilter(scope: .length(.evening), playStyle: .default))
        #expect(evening.contains(1) && evening.contains(9))    // 2 h 14 main-only → ≈ 2.8 h < 4 h
        let unmeasured = try await ids(LibraryFilter(scope: .unmeasured, playStyle: .default))
        #expect(!unmeasured.contains(1) && !unmeasured.contains(9))
        #expect(unmeasured.contains(2) && unmeasured.contains(3))
        let noEstimate = try await ids(LibraryFilter(includeNoTimeEstimate: true))
        #expect(!noEstimate.contains(1))
        #expect(noEstimate.contains(2))
        let suspicious = try await ids(LibraryFilter(includeSuspiciousEstimate: true))
        #expect(!suspicious.contains(1))
    }

    // MARK: - D1a through the store

    private func akira() -> HLTBCandidate {
        HLTBCandidate(id: 29582, name: "Akira", releaseYear: 1988, mainSeconds: 8070,
                      allStylesSeconds: 8070, mainCount: 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func fillAndReplaceWriteTheMainStoryIntoTheMainSlot() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (1, 'Akira', 1)")
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_normally_s, ttb_source) VALUES (2, 'Kept', 1, ?, 'igdb')
                """, arguments: [3 * h])
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_hastily_s, ttb_source, hltb_id) VALUES (3, 'Old', 1, 8070, 'hltb', 29582)
                """)
        }
        let store = LibraryStore(db)

        // Fill: an empty game gets main + rushed, completionist stays empty.
        let r1 = try await store.applyHLTBTimes(gameID: 1, candidate: akira())
        #expect(r1.wroteNormally && r1.wroteHastily && !r1.wroteCompletely)
        let d1 = try await store.gameDetail(id: 1)
        #expect(d1?.ttbNormallyS == 8070 && d1?.ttbHastilyS == 8070 && d1?.ttbCompletelyS == nil)
        #expect(d1?.ttbSource == "hltb")

        // Fill never overwrites an IGDB main.
        _ = try await store.applyHLTBTimes(gameID: 2, candidate: akira())
        let d2 = try await store.gameDetail(id: 2)
        #expect(d2?.ttbNormallyS == 3 * h && d2?.ttbHastilyS == 8070 && d2?.ttbSource == "igdb")

        // Replace (Refresh / Link & Use): the old rushed-only row becomes main + rushed.
        let r3 = try await store.replaceHLTBTimes(gameID: 3, candidate: akira())
        #expect(r3.didWrite)
        let d3 = try await store.gameDetail(id: 3)
        #expect(d3?.ttbNormallyS == 8070 && d3?.ttbHastilyS == 8070 && d3?.ttbCompletelyS == nil)
    }
}
