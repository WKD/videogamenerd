import Foundation
import Testing
import GRDB
@testable import VGN

/// Per-genre pace, data side (PLAN §7b "Per-genre pace"): the per-game SQL factor ≡ the Swift
/// mirror over games with 0 / 1 / several genres (qualifying or not), the measurement read from a
/// library, and its reach (shelves + counts + Length sort, Stats backlog). In-memory databases only.
@Suite(.timeLimit(.minutes(2)))
struct GenrePaceStoreTests {
    private let h = 3600

    private static let genres: [(Int64, String)] = [
        (1, "Point-and-click"), (2, "Puzzle"), (3, "Adventure"), (4, "Shooter"), (5, "Indie"),
    ]

    /// Global 1.81; three qualifying genres (quantized, like the measurement).
    private let profile = PaceProfile(global: 1.81, genres: [
        .init(id: 1, name: "Point-and-click", factor: PaceProfile.quantize(2.787), sampleCount: 32),
        .init(id: 2, name: "Puzzle", factor: PaceProfile.quantize(2.408), sampleCount: 58),
        .init(id: 3, name: "Adventure", factor: PaceProfile.quantize(1.943), sampleCount: 98),
    ])

    private func seedGenres(_ db: AppDatabase) async throws {
        try await db.dbWriter.write { db in
            for (id, name) in Self.genres {
                try db.execute(sql: "INSERT INTO genres (id, name) VALUES (?, ?)", arguments: [id, name])
            }
        }
    }

    @discardableResult
    private func insert(_ db: AppDatabase, id: Int64, genres: [Int64] = [], played: Bool = false,
                        status: String? = nil, psn: Int? = nil,
                        main: Int? = nil, completionist: Int? = nil, owned: Bool = true) async throws -> Int64 {
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, played, status, psn_playtime_s, ttb_normally_s, ttb_completely_s)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, "g\(id)", played ? 1 : 0, status, psn, main, completionist])
            for genre in genres {
                try db.execute(sql: "INSERT INTO game_genres (game_id, genre_id) VALUES (?, ?)",
                               arguments: [id, genre])
            }
            if owned {
                try db.execute(sql: """
                    INSERT INTO products (kind, title, platform_id, format, source)
                    VALUES ('single', ?, 'pc', 'digital', 'manual')
                    """, arguments: ["g\(id)"])
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id) VALUES (?, ?)",
                               arguments: [db.lastInsertedRowID, id])
            }
        }
        return id
    }

    // MARK: - SQL ≡ Swift

    @Test func perGameFactorSQLMatchesSwift() async throws {
        let db = try await TestDB.makeSeeded()
        try await seedGenres(db)
        // (id, genres, main, completionist)
        let rows: [(Int64, [Int64], Int?, Int?)] = [
            (1, [], 30 * h, 90 * h),                           // no genre → global
            (2, [1], 12 * h, nil),                              // one qualifying
            (3, [4], nil, 40 * h),                              // one non-qualifying → global
            (4, [1, 2, 3], 13 * 3600 + 17, 29 * 3600 + 41),     // several qualifying → mean
            (5, [2, 4, 5], 7 * h + 1, nil),                     // qualifying + not
            (6, [1, 3], 1, 3),                                  // tiny odd seconds
            (7, [2], nil, nil),                                 // unmeasured stays NULL
            (8, [4, 5], 45 * h + 59, 101 * h + 7),              // only non-qualifying
        ]
        for (id, genres, m, c) in rows {
            try await insert(db, id: id, genres: genres, main: m, completionist: c, owned: false)
        }
        let names = Dictionary(uniqueKeysWithValues: Self.genres)
        for profile in [profile, .uniform(1.37), .neutral,
                        PaceProfile(global: 1.0, genres: [.init(id: 5, name: "Indie", factor: 0.8, sampleCount: 10)])] {
            for style in PlayStyle.allCases {
                let expr = LibraryQuery.lengthEstimateExpr(style: style, paceFactor: profile)
                let factorExpr = LibraryQuery.paceFactorSQL(profile)
                let sql: [Int64: (Int?, Double)] = try await db.dbWriter.read { db in
                    var out: [Int64: (Int?, Double)] = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT id, \(expr) AS est, \(factorExpr) AS f FROM games g") {
                        out[row["id"]] = (row["est"], row["f"])
                    }
                    return out
                }
                for (id, genres, m, c) in rows {
                    let gNames = genres.compactMap { names[$0] }
                    let f = profile.factor(genreNames: gNames)
                    let swift = PersonalLength.compute(normallyS: m, completelyS: c, style: style, paceFactor: f)?.seconds
                    #expect(sql[id]?.1 == f, "factor id \(id) \(profile)")
                    #expect(sql[id]?.0 == swift, "id \(id) style \(style) profile \(profile)")
                }
            }
        }
        // The Swift mirror resolves the expected factors.
        #expect(profile.factor(genreNames: ["Puzzle", "Shooter", "Indie"]) == PaceProfile.quantize(2.408))
        #expect(profile.factor(genreNames: ["Shooter"]) == 1.81)
    }

    @Test func uniformProfileIsAPlainLiteral() {
        #expect(LibraryQuery.paceFactorSQL(.uniform(1.3)) == "1.3")
        #expect(LibraryQuery.paceFactorSQL(.neutral) == "1.0")
        #expect(LibraryQuery.paceFactorSQL(profile).contains("game_genres"))
    }

    // MARK: - Measurement from a library

    @Test func measuresPerGenreFromTheLibrary() async throws {
        let db = try await TestDB.makeSeeded()
        try await seedGenres(db)
        var id: Int64 = 0
        func finished(_ ratio: Double, _ genres: [Int64]) async throws {
            id += 1
            try await insert(db, id: id, genres: genres, played: true, status: "finished",
                             psn: Int(ratio * 10 * 3600), main: 10 * h)
        }
        for _ in 0..<12 { try await finished(2.0, [1, 3]) }      // Point-and-click + Adventure
        for _ in 0..<15 { try await finished(1.5, [4]) }         // Shooter
        try await finished(0.07, [1])                            // incomplete tracking → set aside
        let pace = try await RecommendationStore(db).paceFactor()
        #expect(pace.sampleCount == 27)
        #expect(pace.setAsideCount == 1)
        #expect(pace.measured == 1.5)                            // 15 × 1.5 then 12 × 2.0 → idx 13
        let expected = PaceProfile.quantize((12 * 2.0 + 5 * 1.5) / 17)
        #expect(pace.genres.map(\.name) == ["Point-and-click", "Adventure", "Shooter"])
        #expect(pace.genres[0].factor == expected && pace.genres[0].sampleCount == 12)
        #expect(pace.genres[2].factor == 1.5)                    // shrink toward itself
    }

    // MARK: - Reach: shelves, counts, sort, Stats

    @Test func shelvesCountsSortAndStatsShiftPerGenre() async throws {
        let db = try await TestDB.makeSeeded()
        try await seedGenres(db)
        let pnc = PaceProfile(global: 1.0, genres: [.init(id: 1, name: "Point-and-click", factor: 2.0, sampleCount: 30)])
        try await insert(db, id: 1, genres: [1], main: 25 * h)       // 50 h for me → A Season
        try await insert(db, id: 2, genres: [4], main: 25 * h)       // 25 h → A Few Weeks
        try await insert(db, id: 3, genres: [], main: 30 * h)        // 30 h → A Few Weeks
        let store = LibraryStore(db)
        func ids(_ shelf: LengthShelf) async throws -> Set<Int64> {
            Set(try await store.gamesOnce(filter: LibraryFilter(scope: .length(shelf), playStyle: .storyFirst,
                                                                 paceFactor: pnc)).map(\.id))
        }
        #expect(try await ids(.season) == [1])
        #expect(try await ids(.fewWeeks) == [2, 3])
        let counts = try await db.dbWriter.read {
            try LibraryQuery.fetchLengthShelfCounts($0, bounds: LengthShelf.bounds(for: .default),
                                                    style: .storyFirst, paceFactor: pnc) }
        #expect(counts.shelves[.season] == 1 && counts.shelves[.fewWeeks] == 2)
        // Length sort (ascending): 25 h, 30 h, then the 50 h point-and-click game.
        let sorted = try await store.gamesOnce(filter: LibraryFilter(scope: .all, playStyle: .storyFirst,
                                                                      paceFactor: pnc, sort: .length))
        #expect(sorted.map(\.id) == [2, 3, 1])
        // Stats "Backlog to beat": 50 + 25 + 30 h.
        let report = try await db.dbWriter.read {
            try LibraryStatsStore.fetchReport($0, scope: .all, playStyle: .storyFirst, paceFactor: pnc,
                                              referenceDate: Date()) }
        #expect(report.myHoursVsAverage.backlogEstimateSeconds == 105 * h)
    }

    // MARK: - Timing (printed, never asserted)

    #if DEBUG
    @Test func gridTimingWithGenreFactors() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let store = LibraryStore(db)
        await PerfSeeder.seed(into: store, count: 2000)
        try await db.dbWriter.write { db in
            for i in 1...12 {
                try db.execute(sql: "INSERT OR IGNORE INTO genres (id, name) VALUES (?, ?)",
                               arguments: [1000 + i, "Genre \(i)"])
            }
            try db.execute(sql: "UPDATE games SET ttb_normally_s = ((id % 60) + 1) * 3600, ttb_completely_s = ((id % 60) + 1) * 7200")
            try db.execute(sql: """
                INSERT OR IGNORE INTO game_genres (game_id, genre_id)
                SELECT id, 1001 + (id % 12) FROM games UNION ALL SELECT id, 1001 + ((id * 7) % 12) FROM games
                """)
        }
        let genreProfile = PaceProfile(global: 1.81, genres: (1...10).map {
            .init(id: Int64(1000 + $0), name: "Genre \($0)", factor: PaceProfile.quantize(1.5 + Double($0) / 20),
                  sampleCount: 20) })
        let clock = ContinuousClock()
        func median(_ runs: Int = 7, _ body: () async throws -> Void) async throws -> Duration {
            var samples: [Duration] = []
            for _ in 0..<runs {
                let start = clock.now
                try await body()
                samples.append(clock.now - start)
            }
            return samples.sorted()[runs / 2]
        }
        var report: [String] = []
        for (label, p) in [("uniform", PaceProfile.uniform(1.81)), ("genre×10", genreProfile)] {
            var n = 0
            let sort = try await median {
                n = try await store.gamesOnce(filter: LibraryFilter(scope: .all, paceFactor: p, sort: .length)).count
            }
            let shelf = try await median {
                _ = try await store.gamesOnce(filter: LibraryFilter(scope: .length(.fewWeeks), paceFactor: p))
            }
            let counts = try await median {
                _ = try await db.dbWriter.read {
                    try LibraryQuery.fetchLengthShelfCounts($0, bounds: LengthShelf.bounds(for: .default),
                                                            style: .default, paceFactor: p) }
            }
            #expect(n == 2000)
            report.append("\(label): length sort \(sort) · fewWeeks shelf \(shelf) · shelf counts \(counts)")
        }
        print("VGN perf: per-genre pace @2000 — " + report.joined(separator: " | "))
    }
    #endif
}
