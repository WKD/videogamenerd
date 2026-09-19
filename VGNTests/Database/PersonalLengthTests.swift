import Foundation
import Testing
import GRDB
@testable import VGN

/// The **personal length** feature (owner request 2026-09-19): how long a game is *for
/// the owner*, a blend of the main (`normally`) and completionist (`completely`)
/// estimates set by a ``PlayStyle`` — the rushed (`hastily`) time is never used. Covers
/// the pure ``PersonalLength/compute`` table, SQL ↔ Swift parity, the shelves / counts /
/// Length sort at t = 0 / 0.5 / 1, the Playtime filter fallback, and the Play Next
/// candidate estimate + "plan for 100%" toggle.
@Suite struct PersonalLengthTests {

    private let h = 3600

    // MARK: - Pure table

    @Test func personalLengthTable() {
        func hrs(_ style: PlayStyle, n: Int?, c: Int?) -> Double? {
            PersonalLength.compute(normallyS: n.map { $0 * 3600 }, completelyS: c.map { $0 * 3600 }, style: style)
                .map { Double($0.seconds) / 3600 }
        }
        // Both sides (30 h main / 90 h completionist): the linear blend by t.
        #expect(hrs(.storyFirst, n: 30, c: 90) == 30)
        #expect(hrs(.someSideQuests, n: 30, c: 90) == 45)
        #expect(hrs(.lotsOfSideQuests, n: 30, c: 90) == 60)   // the owner's default
        #expect(hrs(.completionist, n: 30, c: 90) == 90)
        // Both present but not approximate.
        #expect(PersonalLength.compute(normallyS: 30 * h, completelyS: 90 * h, style: .lotsOfSideQuests)?.isApproximate == false)

        // Dirty data: completely < normally clamps up to normally (no negative blend).
        #expect(hrs(.completionist, n: 40, c: 20) == 40)
        #expect(hrs(.lotsOfSideQuests, n: 40, c: 20) == 40)

        // Only main (R = 1.5): normally · (1 + t·0.5). Marked approximate.
        #expect(hrs(.storyFirst, n: 30, c: nil) == 30)
        #expect(hrs(.lotsOfSideQuests, n: 30, c: nil) == 37.5)
        #expect(hrs(.completionist, n: 30, c: nil) == 45)
        #expect(PersonalLength.compute(normallyS: 30 * h, completelyS: nil, style: .storyFirst)?.isApproximate == true)

        // Only completionist: completely · (1 + t·0.5) / R. Marked approximate.
        #expect(hrs(.storyFirst, n: nil, c: 90) == 60)
        #expect(hrs(.lotsOfSideQuests, n: nil, c: 90) == 75)
        #expect(hrs(.completionist, n: nil, c: 90) == 90)
        #expect(PersonalLength.compute(normallyS: nil, completelyS: 90 * h, style: .completionist)?.isApproximate == true)

        // Rushed-only or nothing → nil (Unmeasured).
        #expect(PersonalLength.compute(normallyS: nil, completelyS: nil, style: .lotsOfSideQuests) == nil)
    }

    @Test func stylePresetPositions() {
        #expect(PlayStyle.storyFirst.t == 0)
        #expect(PlayStyle.someSideQuests.t == 0.25)
        #expect(PlayStyle.lotsOfSideQuests.t == 0.5)
        #expect(PlayStyle.completionist.t == 1)
        #expect(PlayStyle.default == .lotsOfSideQuests)
    }

    // MARK: - SQL ↔ Swift parity

    @Test func sqlMirrorsTheSwiftFunctionForEveryCase() async throws {
        let db = try AppDatabase.inMemory()
        // (id, normally?, completely?) covering both sides, each single side, the clamp,
        // rushed-only (never used), and nothing.
        let rows: [(Int64, Int?, Int?)] = [
            (1, 30 * h, 90 * h),     // both
            (2, 40 * h, 20 * h),     // dirty clamp (completely < normally)
            (3, 25 * h, nil),        // main only
            (4, nil, 80 * h),        // completionist only
            (5, nil, nil),           // nothing (rushed only, below)
            (6, 7 * h, 7 * h),       // equal sides
        ]
        try await db.dbWriter.write { db in
            for (id, n, c) in rows {
                try db.execute(sql: "INSERT INTO games (id, title, played, ttb_normally_s, ttb_completely_s) VALUES (?, ?, 0, ?, ?)",
                               arguments: [id, "g\(id)", n, c])
            }
            // A rushed-only game (id 5 already has both nil; add a distinct rushed-only one).
            try db.execute(sql: "INSERT INTO games (id, title, played, ttb_hastily_s) VALUES (7, 'rushed', 0, ?)",
                           arguments: [5 * h])
        }

        for style in PlayStyle.allCases {
            let expr = LibraryQuery.lengthEstimateExpr(style: style)
            let sqlValues: [Int64: Int?] = try await db.dbWriter.read { db in
                var out: [Int64: Int?] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, \(expr) AS est FROM games g") {
                    out[row["id"]] = row["est"]
                }
                return out
            }
            for (id, n, c) in rows {
                let swift = PersonalLength.compute(normallyS: n, completelyS: c, style: style)?.seconds
                #expect(sqlValues[id] ?? nil == swift, "id \(id) style \(style): SQL \(String(describing: sqlValues[id] ?? nil)) vs Swift \(String(describing: swift))")
            }
            // Rushed-only game 7 → NULL both in SQL and Swift.
            #expect(sqlValues[7] ?? nil == nil, "rushed-only must be NULL at \(style)")
        }
    }

    // MARK: - Shelves move with the style

    @Test func aThirtyNinetyGameMovesShelfWithTheStyle() async throws {
        let store = try await TestDB.makeStore()
        // 30 h main / 90 h completionist. Default pace 8 ⇒ edges 4 / 10 / 40 / 80.
        let g = try await store.addGame(GameDraft(title: "RPG", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: 30 * h, ttbCompletelyS: 90 * h))

        func inShelf(_ shelf: LengthShelf, _ style: PlayStyle) async throws -> Bool {
            let rows = try await store.gamesOnce(filter: LibraryFilter(scope: .length(shelf), playStyle: style))
            return rows.contains { $0.id == g.gameID }
        }
        // Story first (30 h) → A Few Weeks (10–40).
        #expect(try await inShelf(.fewWeeks, .storyFirst))
        #expect(!(try await inShelf(.season, .storyFirst)))
        // Lots of side quests (60 h) → A Season (40–80).
        #expect(try await inShelf(.season, .lotsOfSideQuests))
        #expect(!(try await inShelf(.fewWeeks, .lotsOfSideQuests)))
        // Completionist (90 h) → Epics (80+).
        #expect(try await inShelf(.epic, .completionist))
    }

    @Test func countsAndSortFollowTheStyle() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "RPG", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: 30 * h, ttbCompletelyS: 90 * h))
        let short = try await store.addGame(GameDraft(title: "Short", igdbID: 2, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: short.gameID, MetadataPatch(ttbNormallyS: 5 * h, ttbCompletelyS: 5 * h))

        let bounds = LengthShelf.bounds(for: .default)
        // Counts: the RPG lands in fewWeeks at story-first, season at lots-of-side-quests.
        let atStory = try await store.dbReader.read { try LibraryQuery.fetchLengthShelfCounts($0, bounds: bounds, style: .storyFirst) }
        #expect(atStory.shelves[.fewWeeks] == 1)
        #expect(atStory.shelves[.season] == 0)
        let atLots = try await store.dbReader.read { try LibraryQuery.fetchLengthShelfCounts($0, bounds: bounds, style: .lotsOfSideQuests) }
        #expect(atLots.shelves[.fewWeeks] == 0)
        #expect(atLots.shelves[.season] == 1)

        // Length sort: shortest first. The RPG (30 h) trails the 5 h game at story-first.
        let ordered = try await store.gamesOnce(
            filter: LibraryFilter(scope: .all, playStyle: .storyFirst, sort: .length, ascending: true)).map(\.id)
        #expect(ordered == [short.gameID, g.gameID])
    }

    // MARK: - Playtime filter fallback uses the personal length

    @Test func playtimeFilterFallbackUsesPersonalLength() async throws {
        let store = try await TestDB.makeStore()
        // Unplayed 30/80 game: at lots-of-side-quests the fallback length is 55 h → h40to60.
        let g = try await store.addGame(GameDraft(title: "RPG", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: 30 * h, ttbCompletelyS: 80 * h))

        func inBand(_ band: PlaytimeBucket, _ style: PlayStyle) async throws -> Bool {
            let rows = try await store.gamesOnce(filter: LibraryFilter(playtimes: [band], scope: .all, playStyle: style))
            return rows.contains { $0.id == g.gameID }
        }
        #expect(try await inBand(.h10to40, .storyFirst))       // 30 h
        #expect(try await inBand(.h40to60, .lotsOfSideQuests)) // 30 + 0.5·50 = 55 h
    }

    // MARK: - Play Next candidate estimate + toggle

    @Test func playNextCandidateEstimateUsesPersonalLength() {
        let candidate = Candidate(id: 1, estimateSeconds: 30 * h, completionistSeconds: 90 * h, status: .backlog)
        // The engine feeds the personal length at the bracket's resolved style.
        #expect(candidate.fullEstimate(style: .storyFirst) == 30 * h)
        #expect(candidate.fullEstimate(style: .lotsOfSideQuests) == 60 * h)
        #expect(candidate.fullEstimate(style: .completionist) == 90 * h)

        // A bracket's "plan for 100%" toggle forces the completionist style.
        let planned = TimeBracket(shelf: .fewWeeks, playStyle: .lotsOfSideQuests, completionist: true)
        #expect(planned.resolvedStyle == .completionist)
        let normal = TimeBracket(shelf: .fewWeeks, playStyle: .lotsOfSideQuests, completionist: false)
        #expect(normal.resolvedStyle == .lotsOfSideQuests)
    }

    @Test @MainActor func completionistToggleForcedWhenStyleIsCompletionist() {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult())
        let defaults = UserDefaults(suiteName: "personallength.\(UUID())")!

        // Owner plays as a completionist → the toggle is forced on and disabled.
        let forced = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                   defaults: defaults, playStyle: .completionist, recomputeDebounce: .milliseconds(1))
        #expect(forced.completionistForced)
        #expect(forced.completionistOn)
        #expect(forced.bracket.resolvedStyle == .completionist)

        // A normal owner style → the toggle is a free per-session override.
        let normal = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                   defaults: UserDefaults(suiteName: "personallength.\(UUID())")!,
                                   playStyle: .lotsOfSideQuests, recomputeDebounce: .milliseconds(1))
        #expect(!normal.completionistForced)
        #expect(!normal.completionistOn)
    }
}
