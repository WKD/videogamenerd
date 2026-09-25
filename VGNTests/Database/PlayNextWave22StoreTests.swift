import Foundation
import Testing
import GRDB
@testable import VGN

/// Wave 22 data side (PLAN §7b "Scheduled 2026-09-25"): the pace factor's SQL ≡ Swift parity
/// and its reach (shelves, counts, Stats backlog), the measured factor from a seeded library,
/// the replay / finish rows end-to-end through ``RecommendationStore``, and the Playtime ▸
/// Estimate Source facet (SQL ≡ the in-memory evaluator). In-memory databases only.
@Suite(.timeLimit(.minutes(1)))
struct PlayNextWave22StoreTests {
    private let h = 3600

    // MARK: - Helpers

    /// Insert a game straight into `games` (+ an owned copy when `owned`).
    @discardableResult
    private func insert(_ db: AppDatabase, id: Int64, title: String? = nil, played: Bool = false,
                        status: String? = nil, revisit: Bool = false, tier: Int64? = nil,
                        holdsUp: String? = nil, lastPlayed: Date? = nil,
                        mine: Int? = nil, psn: Int? = nil, batocera: Int? = nil,
                        rushed: Int? = nil, main: Int? = nil, completionist: Int? = nil,
                        source: String? = nil, owned: Bool = true) async throws -> Int64 {
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, played, status, revisit, tier_id, holds_up, last_played_at,
                                   my_playtime_s, psn_playtime_s, batocera_playtime_s,
                                   ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, title ?? "g\(id)", played ? 1 : 0, status, revisit ? 1 : 0, tier, holdsUp,
                                 lastPlayed, mine, psn, batocera, rushed, main, completionist, source])
            if owned {
                try db.execute(sql: """
                    INSERT INTO products (kind, title, platform_id, format, source) VALUES ('single', ?, 'pc', 'digital', 'manual')
                    """, arguments: [title ?? "g\(id)"])
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id) VALUES (?, ?)",
                               arguments: [db.lastInsertedRowID, id])
            }
        }
        return id
    }

    // MARK: - SQL ≡ Swift with the factor

    @Test func personalLengthSQLMatchesSwiftAcrossFactors() async throws {
        let db = try await TestDB.makeSeeded()
        let rows: [(Int64, Int?, Int?, Int?, String?)] = [
            (1, nil, 30 * h, 90 * h, nil),
            (2, nil, 12 * h, nil, nil),
            (3, nil, nil, 40 * h, nil),
            (4, nil, 10 * h, 60 * h, nil),          // flagged completionist → fallback
            (5, 7 * h, nil, nil, "hltb"),           // HLTB Main-Story-only read rule
            (6, 5 * h, nil, nil, "igdb"),           // rushed only → unmeasured
            (7, nil, 13 * 3600 + 17, 29 * 3600 + 41, nil),   // odd seconds, rounding
        ]
        for (id, r, m, c, s) in rows {
            try await insert(db, id: id, rushed: r, main: m, completionist: c, source: s, owned: false)
        }
        for factor in [0.8, 1.0, 1.3, 1.37, 2.0] {
            for style in PlayStyle.allCases {
                let expr = LibraryQuery.lengthEstimateExpr(style: style, paceFactor: factor)
                let sql: [Int64: Int?] = try await db.dbWriter.read { db in
                    var out: [Int64: Int?] = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT id, \(expr) AS est FROM games g") {
                        out[row["id"]] = row["est"]
                    }
                    return out
                }
                for (id, r, m, c, s) in rows {
                    let inputs = EstimateSanity.lengthInputs(rushed: r, main: m, completionist: c,
                                                             sourceIsHLTB: s == "hltb", dismissed: false)
                    let swift = PersonalLength.compute(normallyS: inputs.main, completelyS: inputs.completionist,
                                                       style: style, paceFactor: factor)?.seconds
                    #expect(sql[id] ?? nil == swift, "id \(id) style \(style) factor \(factor)")
                }
            }
        }
    }

    @Test func shelvesCountsAndSortShiftWithTheFactor() async throws {
        let store = try await TestDB.makeStore()
        // 35 h main: A Few Weeks (10–40) at 1.0×, A Season (40–80) at 1.3× (45.5 h).
        let g = try await store.addGame(GameDraft(title: "RPG", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: 35 * h))
        func inShelf(_ shelf: LengthShelf, _ factor: Double) async throws -> Bool {
            let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .length(shelf), paceFactor: factor))
            return rows.contains { $0.id == g.gameID }
        }
        #expect(try await inShelf(.fewWeeks, 1.0))
        #expect(!(try await inShelf(.season, 1.0)))
        #expect(try await inShelf(.season, 1.3))
        #expect(!(try await inShelf(.fewWeeks, 1.3)))
        let bounds = LengthShelf.bounds(for: .default)
        let one = try await store.dbReader.read {
            try LibraryQuery.fetchLengthShelfCounts($0, bounds: bounds, style: .storyFirst, paceFactor: 1.0) }
        let slow = try await store.dbReader.read {
            try LibraryQuery.fetchLengthShelfCounts($0, bounds: bounds, style: .storyFirst, paceFactor: 1.3) }
        #expect(one.shelves[.fewWeeks] == 1 && one.shelves[.season] == 0)
        #expect(slow.shelves[.fewWeeks] == 0 && slow.shelves[.season] == 1)
        #expect(one.unmeasured == slow.unmeasured)   // a factor never changes what is measured
    }

    // MARK: - The measured factor from a library

    @Test func measuredFactorFromTheLibrary() async throws {
        let db = try await TestDB.makeSeeded()
        // Five finished games at 1.2, 1.3, 1.3, 1.5, 1.6 of main → median 1.3.
        for (i, ratio) in [1.2, 1.3, 1.3, 1.5, 1.6].enumerated() {
            try await insert(db, id: Int64(i + 1), played: true, status: "finished",
                             psn: Int(ratio * 10 * 3600), main: 10 * h)
        }
        // A 100 % game measured on completionist (30 h vs 20 h = 1.5); manual beats PSN.
        try await insert(db, id: 10, played: true, status: "completed", mine: 30 * h, psn: 99 * h,
                         main: 10 * h, completionist: 20 * h)
        // Excluded: suspicious (completionist ≥ 4× main), playing, no estimate, no play time.
        try await insert(db, id: 20, played: true, status: "finished", psn: 50 * h, main: 10 * h, completionist: 60 * h)
        try await insert(db, id: 21, played: true, status: "playing", psn: 30 * h, main: 10 * h)
        try await insert(db, id: 22, played: true, status: "finished", psn: 30 * h)
        try await insert(db, id: 23, played: true, status: "finished", main: 10 * h)
        let factor = try await RecommendationStore(db).paceFactor()
        #expect(factor.sampleCount == 6)
        // Ratios 1.2 1.3 1.3 1.5 (the 100 % one) 1.5 1.6 → median (1.3 + 1.5) / 2.
        #expect(abs(factor.measured - 1.4) < 1e-9)
    }

    @Test func statsBacklogUsesTheFactorAndItsOverride() async throws {
        let db = try await TestDB.makeSeeded()
        for i in 1...5 {   // five finished games at 2.0× → measured factor 2.0
            try await insert(db, id: Int64(i), played: true, status: "finished", psn: 20 * h, main: 10 * h)
        }
        try await insert(db, id: 50, main: 10 * h)   // the backlog: one owned, unplayed 10 h game
        let stats = LibraryStatsStore(db)
        let measured = try await stats.report(scope: .all, playStyle: .storyFirst)
        #expect(measured.myHoursVsAverage.backlogEstimateSeconds == 20 * h)
        let overridden = try await stats.report(scope: .all, playStyle: .storyFirst, paceFactorOverride: 1.0)
        #expect(overridden.myHoursVsAverage.backlogEstimateSeconds == 10 * h)
        // "Me vs. average" keeps the raw advertised time.
        #expect(measured.myHoursVsAverage.averageSeconds == overridden.myHoursVsAverage.averageSeconds)
    }

    // MARK: - Rows end-to-end

    @Test func rowsEndToEndThroughTheStore() async throws {
        let db = try await TestDB.makeSeeded()
        let calendar = Calendar(identifier: .gregorian)
        let long = calendar.date(from: DateComponents(year: 2019, month: 5, day: 1))!
        let recent = Date().addingTimeInterval(-30 * 24 * 3600)
        // Taste profile: ranked games (played + tier).
        for i in 1...16 { try await insert(db, id: Int64(i), played: true, status: "finished", tier: 3) }
        // Almost there: Playing, 18 h of a 20 h game.
        try await insert(db, id: 100, title: "Nearly", played: true, status: "playing", psn: 18 * h, main: 20 * h)
        // Replay: S, holds up, last played 2019 → eligible; one undated; one too recent; one B.
        try await insert(db, id: 200, title: "Classic", played: true, status: "completed", tier: 1,
                         holdsUp: "holds_up", lastPlayed: long, main: 12 * h)
        try await insert(db, id: 201, played: true, status: "finished", tier: 2, holdsUp: "holds_up", main: 12 * h)
        try await insert(db, id: 202, played: true, status: "finished", tier: 1, holdsUp: "holds_up",
                         lastPlayed: recent, main: 12 * h)
        try await insert(db, id: 203, played: true, status: "finished", tier: 3, holdsUp: "holds_up",
                         lastPlayed: long, main: 12 * h)
        // A plain backlog game so the regular picks are not empty.
        try await insert(db, id: 300, main: 20 * h)

        let rec = RecommendationStore(db)
        let result = try await rec.recommend(bracket: TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst))
        #expect(result.finishWhatYouStarted.map(\.id) == [100])
        #expect(result.finishWhatYouStarted.first?.reasons.first
                == .almostThere(remainingSeconds: 2 * h, pastEstimate: false))
        #expect(result.replay.map(\.id) == [200])
        #expect(result.replay.first?.reasons.first == .replayWorthy(tierLetter: "S", lastPlayedYear: 2019))
        #expect(result.replayUndatedCount == 1)
        #expect(result.shortlist.map(\.id) == [300])

        // "Start playing" on the replay card sets Playing; undo restores 100 %.
        let token = try await rec.startPlayingCapturingUndo(gameID: 200)
        #expect(try await LibraryStore(db).gameDetail(id: 200)?.status == .playing)
        #expect(try await rec.undoStartPlaying(token) == .restored)
        #expect(try await LibraryStore(db).gameDetail(id: 200)?.status == .completed)
    }

    // MARK: - Estimate Source facet

    @Test func estimateSourceFacetSQLMatchesTheEvaluator() async throws {
        let db = try await TestDB.makeSeeded()
        try await insert(db, id: 1, main: 10 * h, source: "igdb")
        try await insert(db, id: 2, rushed: 5 * h, source: "hltb")
        try await insert(db, id: 3, main: 10 * h, source: nil)         // legacy untagged → IGDB
        try await insert(db, id: 4)                                     // none
        try await insert(db, id: 5, source: "hltb")                     // tagged but empty → none
        try await insert(db, id: 6, completionist: 30 * h, source: "hltb")
        let store = LibraryStore(db)
        let all = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        #expect(Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.estimateSource) })
                == [1: .igdb, 2: .hltb, 3: .igdb, 4: .none, 5: .none, 6: .hltb])
        let subsets: [Set<EstimateSource>] = [[.igdb], [.hltb], [.none], [.igdb, .none], [.igdb, .hltb, .none]]
        for subset in subsets {
            let filter = LibraryFilter(estimateSources: subset, scope: .all)
            let sql = Set(try await store.gamesOnce(filter: filter).map(\.id))
            let memory = Set(LibraryFilterEvaluator.apply(filter, to: all).map(\.id))
            #expect(sql == memory, "\(subset)")
        }
        // Composable: AND with another facet.
        let both = try await store.gamesOnce(filter: LibraryFilter(estimateSources: [.hltb], platforms: ["pc"], scope: .all))
        #expect(Set(both.map(\.id)) == [2, 6])
        // The Swift rule agrees with the SQL on the same rows.
        #expect(EstimateSource.classify(rushed: nil, main: nil, completionist: nil, source: "hltb") == .none)
        #expect(EstimateSource.classify(rushed: 1, main: nil, completionist: nil, source: "hltb") == .hltb)
        #expect(EstimateSource.classify(rushed: nil, main: 1, completionist: nil, source: nil) == .igdb)
    }

    @Test func estimateSourceChipIsItsOwnRemovableGroup() {
        let f = LibraryFilter(includeSuspiciousEstimate: true, estimateSources: [.none, .hltb])
        let chips = LibraryFilterChips.chips(for: f).filter { $0.kind == .estimateSource }
        #expect(chips.map(\.text) == ["Estimate Source: HowLongToBeat", "or None"])
        let removed = LibraryFilterChips.removing(chips[0], from: f)
        #expect(removed.estimateSources == [.none])
        #expect(removed.includeSuspiciousEstimate)
        #expect(LibraryFilterChips.cleared(f).estimateSources.isEmpty)
        #expect(f.hasActiveFacets)
        // "Clear all" keeps the pace factor (not a facet).
        var paced = f
        paced.paceFactor = 1.4
        #expect(LibraryFilterChips.cleared(paced).paceFactor == 1.4)
    }
}
