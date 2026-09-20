import Foundation
import Testing
import GRDB
@testable import VGN

/// The suspicious-estimate rule (PLAN §5.3, owner 2026-09-20): the pure Swift rule, its
/// human sentences, and — the load-bearing one — that the SQL fragment in ``LibraryQuery``
/// agrees with the Swift rule on a table of cases, including NULLs, equal values, the
/// `hltb`-source exemption and dismissals. Also the personal-length fallback (D5) agrees
/// between the Swift `lengthInputs` + `PersonalLength.compute` path and the SQL
/// `lengthEstimateExpr`.
@Suite struct EstimateSanityTests {

    private let h = 3600

    /// (id, rushed?, main?, completionist?, source?, dismissed) — meanings:
    /// rushed = ttb_hastily_s, main = ttb_normally_s, completionist = ttb_completely_s.
    private struct Case {
        let id: Int64
        let r: Int?, m: Int?, c: Int?
        let source: String?
        let dismissed: Bool
    }

    private func cases() -> [Case] {
        let h = self.h
        return [
            Case(id: 1,  r: nil,      m: nil,     c: nil,       source: nil,    dismissed: false), // nothing
            Case(id: 2,  r: nil,      m: 10 * h,  c: nil,       source: nil,    dismissed: false), // main only (ok)
            Case(id: 3,  r: nil,      m: nil,     c: 20 * h,    source: nil,    dismissed: false), // completionist only → flagged
            Case(id: 4,  r: nil,      m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // ordered 2× (ok)
            Case(id: 5,  r: nil,      m: 10 * h,  c: 40 * h,    source: nil,    dismissed: false), // c == 4m → flagged
            Case(id: 6,  r: nil,      m: 10 * h,  c: 39 * h,    source: nil,    dismissed: false), // c = 3.9m (ok)
            Case(id: 7,  r: nil,      m: 10 * h,  c: 5 * h,     source: nil,    dismissed: false), // main > completionist → flagged
            Case(id: 8,  r: 5 * h,    m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // rushed < main (ok)
            Case(id: 9,  r: 12 * h,   m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // rushed > main → flagged
            Case(id: 10, r: 1 * h,    m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // rushed < 0.25m → flagged
            Case(id: 11, r: 9000,     m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // rushed == 0.25m (ok, boundary)
            Case(id: 12, r: 10 * h,   m: 10 * h,  c: 20 * h,    source: nil,    dismissed: false), // rushed == main (ok, boundary)
            Case(id: 13, r: nil,      m: 10 * h,  c: 10 * h,    source: nil,    dismissed: false), // main == completionist (ok)
            Case(id: 14, r: nil,      m: 10 * h,  c: 100 * h,   source: "hltb", dismissed: false), // hltb → never flagged
            Case(id: 15, r: nil,      m: 10 * h,  c: 100 * h,   source: nil,    dismissed: true),  // dismissed → never flagged
            Case(id: 16, r: nil,      m: 3601,    c: 20000,     source: nil,    dismissed: false), // flagged, non-integer main×r rounding
            Case(id: 17, r: 90 * h,   m: 2 * h,   c: 90 * h,    source: nil,    dismissed: false), // rushed>main AND c≥4m → flagged
        ]
    }

    private func seed() async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        let store = LibraryStore(db)
        try await db.dbWriter.write { db in
            for c in self.cases() {
                try db.execute(sql: """
                    INSERT INTO games (id, title, played, ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                    VALUES (?, ?, 0, ?, ?, ?, ?)
                    """, arguments: [c.id, "g\(c.id)", c.r, c.m, c.c, c.source])
            }
        }
        for c in cases() where c.dismissed {
            try await store.setEstimateLooksRight(gameID: c.id, dismissed: true)
        }
        return store
    }

    // MARK: - Swift ≡ SQL: the flag

    @Test func swiftAndSqlAgreeOnWhichGamesAreFlagged() async throws {
        let store = try await seed()
        let dismissed = Set(cases().filter(\.dismissed).map(\.id))

        let sqlFlagged: Set<Int64> = try await store.dbReader.read { db in
            Set(try Int64.fetchAll(db, sql: """
                SELECT id FROM games g WHERE \(LibraryQuery.suspiciousEstimatePredicate())
                """))
        }
        var swiftFlagged: Set<Int64> = []
        for c in cases() where EstimateSanity.isFlagged(
            rushed: c.r, main: c.m, completionist: c.c,
            sourceIsHLTB: c.source == "hltb", dismissed: dismissed.contains(c.id)) {
            swiftFlagged.insert(c.id)
        }
        #expect(sqlFlagged == swiftFlagged, "SQL \(sqlFlagged.sorted()) vs Swift \(swiftFlagged.sorted())")
        // Sanity: the expected flagged set (3,5,7,9,10,16,17) — hltb (14) and dismissed (15) excluded.
        #expect(swiftFlagged == [3, 5, 7, 9, 10, 16, 17])
    }

    // MARK: - Swift ≡ SQL: the personal-length fallback (D5)

    @Test func swiftAndSqlAgreeOnPersonalLengthWithFallback() async throws {
        let store = try await seed()
        let dismissed = Set(cases().filter(\.dismissed).map(\.id))

        for style in PlayStyle.allCases {
            let expr = LibraryQuery.lengthEstimateExpr(style: style)
            let sqlValues: [Int64: Int?] = try await store.dbReader.read { db in
                var out: [Int64: Int?] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, \(expr) AS est FROM games g") {
                    out[row["id"]] = row["est"]
                }
                return out
            }
            for c in cases() {
                let li = EstimateSanity.lengthInputs(
                    rushed: c.r, main: c.m, completionist: c.c,
                    sourceIsHLTB: c.source == "hltb", dismissed: dismissed.contains(c.id))
                let swift = PersonalLength.compute(normallyS: li.main, completelyS: li.completionist, style: style)?.seconds
                #expect((sqlValues[c.id] ?? nil) == swift,
                        "id \(c.id) style \(style): SQL \(String(describing: sqlValues[c.id] ?? nil)) vs Swift \(String(describing: swift))")
            }
        }
    }

    /// The completionist-inflated fallback: a 10 h / 60 h game (60 ≥ 4×10) plans as if it
    /// were a 10 h main-only game (10 × 1.5 = 15 h completionist), so at "lots of side
    /// quests" (t = 0.5) the personal length is 12.5 h, not 35 h.
    @Test func completionistFallbackShrinksThePersonalLength() {
        let flagged = EstimateSanity.lengthInputs(rushed: nil, main: 10 * h, completionist: 60 * h,
                                                  sourceIsHLTB: false, dismissed: false)
        #expect(flagged.main == 10 * h)
        #expect(flagged.completionist == Int((Double(10 * h) * PlayStyle.sidesRatio).rounded())) // 15 h
        let len = PersonalLength.compute(normallyS: flagged.main, completelyS: flagged.completionist,
                                         style: .lotsOfSideQuests)!
        #expect(len.seconds == Int((Double(10 * h) * (1 + 0.5 * (PlayStyle.sidesRatio - 1))).rounded())) // 12.5 h
        // Dismissed / hltb keep the raw pair (35 h at t = 0.5).
        let raw = EstimateSanity.lengthInputs(rushed: nil, main: 10 * h, completionist: 60 * h,
                                              sourceIsHLTB: false, dismissed: true)
        #expect(raw.completionist == 60 * h)
    }

    // MARK: - Pure rule + human sentences (D1)

    @Test func ruleReturnsTheRightReasonWithAHumanSentence() {
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: 54 * h, completionist: 1000 * h)
                == .completionistTooLong(main: 54 * h, completionist: 1000 * h))
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: 54 * h, completionist: 1000 * h)?.sentence
                == "Completionist (1000 h) is more than 4× the main story (54 h).")

        #expect(EstimateSanity.isSuspicious(rushed: 12 * h, main: 10 * h, completionist: 20 * h)
                == .rushedOverMain(rushed: 12 * h, main: 10 * h))
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: 10 * h, completionist: 5 * h)
                == .mainOverCompletionist(main: 10 * h, completionist: 5 * h))
        #expect(EstimateSanity.isSuspicious(rushed: 1 * h, main: 10 * h, completionist: 20 * h)
                == .rushedTooShort(rushed: 1 * h, main: 10 * h))
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: nil, completionist: 20 * h)
                == .completionistWithoutMain(completionist: 20 * h))

        // Not suspicious: ordered, main-only, nothing, boundary equals.
        #expect(EstimateSanity.isSuspicious(rushed: 5 * h, main: 10 * h, completionist: 20 * h) == nil)
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: 10 * h, completionist: nil) == nil)
        #expect(EstimateSanity.isSuspicious(rushed: nil, main: nil, completionist: nil) == nil)
        #expect(EstimateSanity.isSuspicious(rushed: 10 * h, main: 10 * h, completionist: 20 * h) == nil)  // rushed == main
        #expect(EstimateSanity.isSuspicious(rushed: 9000, main: 10 * h, completionist: 20 * h) == nil)    // rushed == 0.25m
    }

    @Test func hltbSourcedAndDismissedAreNeverFlagged() {
        // A wild completionist would be flagged, but the source / dismissal exempt it.
        #expect(EstimateSanity.isFlagged(rushed: nil, main: 10 * h, completionist: 500 * h,
                                         sourceIsHLTB: true, dismissed: false) == false)
        #expect(EstimateSanity.isFlagged(rushed: nil, main: 10 * h, completionist: 500 * h,
                                         sourceIsHLTB: false, dismissed: true) == false)
        #expect(EstimateSanity.isFlagged(rushed: nil, main: 10 * h, completionist: 500 * h,
                                         sourceIsHLTB: false, dismissed: false) == true)
    }
}
