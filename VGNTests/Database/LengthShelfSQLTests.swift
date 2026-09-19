import Foundation
import Testing
import GRDB
@testable import VGN

/// Data-layer tests for the sidebar "By Length" shelves (PLAN §8): the SQL scope per
/// shelf (edges + the normally→hastily→completely estimate fallback), the "Unmeasured"
/// catch-all, that the shelf counts come from ONE query and agree with the scopes,
/// that the owner's own playtime never moves a game between shelves, and that the
/// pace re-bands games.
@Suite struct LengthShelfSQLTests {

    private let h = 3600

    private func ids(_ store: LibraryStore, _ scope: SidebarSelection,
                     pace: PlayPace = .default) async throws -> Set<Int64> {
        Set(try await store.gamesOnce(filter: LibraryFilter(scope: scope, playPace: pace)).map(\.id))
    }

    /// Add an owned game whose only time signal is a *normally* estimate.
    private func addEstimate(_ store: LibraryStore, _ title: String, igdb: Int64,
                             normallyS: Int) async throws -> Int64 {
        let g = try await store.addGame(GameDraft(title: title, igdbID: igdb, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: normallyS))
        return g.gameID
    }

    // MARK: - Scope per shelf, at the edges (default pace 4/10/40/80)

    @Test func shelfScopesBandByEstimateAtEdges() async throws {
        let store = try await TestDB.makeStore()
        // (label, estimate seconds, expected shelf)
        let cases: [(String, Int, LengthShelf)] = [
            ("s1", 3 * h + 59 * 60, .evening),   // 3:59 → One Evening
            ("s2", 4 * h,           .weekend),   // 4:00 → A Weekend
            ("s3", 9 * h + 59 * 60, .weekend),   // 9:59 → A Weekend
            ("s4", 10 * h,          .fewWeeks),  // 10:00 → A Few Weeks
            ("s5", 39 * h + 59 * 60, .fewWeeks), // 39:59 → A Few Weeks
            ("s6", 40 * h,          .season),    // 40:00 → A Season
            ("s7", 79 * h + 59 * 60, .season),   // 79:59 → A Season
            ("s8", 80 * h,          .epic),      // 80:00 → Epics
        ]
        var idByLabel: [String: Int64] = [:]
        for (i, c) in cases.enumerated() {
            idByLabel[c.0] = try await addEstimate(store, c.0, igdb: Int64(200 + i), normallyS: c.1)
        }
        // A game with no estimate at all → Unmeasured, in no shelf.
        let none = try await store.addGame(GameDraft(title: "None", igdbID: 999, platformIDs: ["pc"], owned: true))

        for shelf in LengthShelf.allCases {
            let inScope = try await ids(store, .length(shelf))
            for c in cases {
                let shouldContain = c.2 == shelf
                #expect(inScope.contains(idByLabel[c.0]!) == shouldContain,
                        "\(c.0) (\(c.1)s) vs shelf \(shelf)")
            }
            #expect(!inScope.contains(none.gameID), "Unmeasured game must be in no shelf")
        }
        #expect(try await ids(store, .unmeasured) == [none.gameID])
    }

    // MARK: - Estimate fallback normally → hastily → completely (never playtime)

    @Test func estimateFallbackOrder() async throws {
        let store = try await TestDB.makeStore()
        // Only completely (20 h) → A Few Weeks.
        let onlyComp = try await store.addGame(GameDraft(title: "C", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: onlyComp.gameID, MetadataPatch(ttbCompletelyS: 20 * h))
        // Only hastily (5 h) → A Weekend.
        let onlyHast = try await store.addGame(GameDraft(title: "H", igdbID: 2, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: onlyHast.gameID, MetadataPatch(ttbHastilyS: 5 * h))
        // normally wins over the others (2 h → One Evening despite a 90 h completely).
        let norm = try await store.addGame(GameDraft(title: "N", igdbID: 3, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: norm.gameID,
                                       MetadataPatch(ttbHastilyS: 90 * h, ttbNormallyS: 2 * h, ttbCompletelyS: 90 * h))

        #expect(try await ids(store, .length(.fewWeeks)) == [onlyComp.gameID])
        #expect(try await ids(store, .length(.weekend)) == [onlyHast.gameID])
        #expect(try await ids(store, .length(.evening)) == [norm.gameID])
    }

    @Test func ownPlaytimeNeverMovesAGameBetweenShelves() async throws {
        let store = try await TestDB.makeStore()
        // A 2 h estimate (One Evening) but 100 h of my own playtime — still One Evening.
        let g = try await store.addGame(GameDraft(title: "Dropped Epic", igdbID: 1,
                                                  platformIDs: ["pc"], owned: true, played: true))
        try await store.updateMetadata(gameID: g.gameID, MetadataPatch(ttbNormallyS: 2 * h))
        try await store.setMyPlaytime(gameID: g.gameID, seconds: 100 * h)

        #expect(try await ids(store, .length(.evening)) == [g.gameID])
        #expect(try await ids(store, .length(.epic)).isEmpty)
    }

    // MARK: - Counts: ONE query, all six numbers, agree with the scopes

    @Test func lengthCountsComeFromOneQueryAndAgreeWithScopes() async throws {
        let store = try await TestDB.makeStore()
        // Spread across shelves + a couple of unmeasured.
        let spread = [1, 2, 6, 12, 30, 50, 70, 120, 300].map { $0 * h }  // hours across every shelf
        for (i, s) in spread.enumerated() { _ = try await addEstimate(store, "g\(i)", igdb: Int64(300 + i), normallyS: s) }
        _ = try await store.addGame(GameDraft(title: "u1", igdbID: 900, platformIDs: ["pc"], owned: true))
        _ = try await store.addGame(GameDraft(title: "u2", igdbID: 901, platformIDs: ["pc"], owned: true, played: true))

        let ds = GRDBLibraryDataSource(store: store)
        let counts = await firstCounts(ds, pace: .default)

        // Every shelf number matches its scope query, from the SAME emitted value.
        for shelf in LengthShelf.allCases {
            let scopeCount = try await ids(store, .length(shelf)).count
            #expect(counts.lengthShelves[shelf] == scopeCount, "shelf \(shelf) count mismatch")
        }
        #expect(counts.unmeasured == (try await ids(store, .unmeasured)).count)
        #expect(counts.unmeasured == 2)
        // The scalar counts still come through the same single observation.
        #expect(counts.all == 11)
    }

    // MARK: - Pace re-bands games

    @Test func changingPaceRebandsGames() async throws {
        let store = try await TestDB.makeStore()
        // A 10 h game: A Few Weeks at pace 8 (10–40), A Season at pace 2 (10–20).
        let g = try await addEstimate(store, "TenHours", igdb: 1, normallyS: 10 * h)
        #expect(try await ids(store, .length(.fewWeeks), pace: .default) == [g])
        #expect(try await ids(store, .length(.season), pace: .default).isEmpty)

        let slow = PlayPace(hoursPerWeek: 2)   // edges 2/3/10/20
        #expect(try await ids(store, .length(.season), pace: slow) == [g])
        #expect(try await ids(store, .length(.fewWeeks), pace: slow).isEmpty)

        // Counts follow the pace through the one observation.
        let ds = GRDBLibraryDataSource(store: store)
        let slowCounts = await firstCounts(ds, pace: slow)
        #expect(slowCounts.lengthShelves[.season] == 1)
        #expect(slowCounts.lengthShelves[.fewWeeks] == 0)
    }

    // MARK: - Combines with facet filters and search (AND across kinds)

    @Test func shelfCombinesWithFilterAndSearch() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "Portal", igdbID: 1, platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: a.gameID, MetadataPatch(ttbNormallyS: 3 * h))   // One Evening, pc
        let b = try await store.addGame(GameDraft(title: "Journey", igdbID: 2, platformIDs: ["ps4"], owned: true))
        try await store.updateMetadata(gameID: b.gameID, MetadataPatch(ttbNormallyS: 3 * h))   // One Evening, ps4

        // Shelf scope AND a platform facet.
        var f = LibraryFilter(platforms: ["pc"], scope: .length(.evening))
        #expect(Set(try await store.gamesOnce(filter: f).map(\.id)) == [a.gameID])
        // Shelf scope AND search text.
        f = LibraryFilter(searchText: "jour", scope: .length(.evening))
        #expect(Set(try await store.gamesOnce(filter: f).map(\.id)) == [b.gameID])
    }

    // MARK: - Printed-timing perf for the extended counts query (no wall-clock assert)

    #if DEBUG
    @Test func lengthCountsPerfAt2000() async throws {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatformsFromBundle(.main)
        let store = LibraryStore(db)
        await PerfSeeder.seed(into: store, count: 2000)
        let bounds = LengthShelf.bounds(for: .default)

        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = clock.now
            _ = try await store.dbReader.read { d -> (SidebarCounts, ([LengthShelf: Int], Int)) in
                (try LibraryStore.fetchSidebarCounts(d),
                 try LibraryQuery.fetchLengthShelfCounts(d, bounds: bounds))
            }
            best = min(best, Double((clock.now - start).components.attoseconds) / 1e15)
        }
        print("VGN by-length counts (scalar+platform+shelves) @2000: \(String(format: "%.2f", best))ms")
        let total = try await store.gamesOnce(filter: LibraryFilter(scope: .all)).count
        #expect(total == 2000)
    }
    #endif

    /// First value from the (open) counts observation, then cancel it.
    private func firstCounts(_ ds: GRDBLibraryDataSource, pace: PlayPace) async -> SidebarCounts {
        for await c in ds.sidebarCounts(pace: pace) { return c }
        return .empty
    }
}
