import Foundation
import Testing
import GRDB
@testable import VGN

/// Data-layer tests for the M5 playtime filter buckets, the sidebar stats
/// aggregates, and the inspector derived-score line (PLAN §6.4/§7).
@Suite struct PlaytimeStatsScoreTests {

    private let h = 3600

    // MARK: - Playtime filter buckets through SQL

    @Test func playtimeBucketsFilterOnEffectiveThenIGDB() async throws {
        let store = try await TestDB.makeStore()
        // Played with manual 5 h → short.
        let a = try await store.addGame(GameDraft(title: "Short One", igdbID: 1, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 5 * h)
        // Played with manual 20 h → medium.
        let b = try await store.addGame(GameDraft(title: "Medium One", igdbID: 2, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: b.gameID, seconds: 20 * h)
        // Played with manual 90 h → 80–100 h band.
        let c = try await store.addGame(GameDraft(title: "Long One", igdbID: 3, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: c.gameID, seconds: 90 * h)
        // Unplayed, IGDB main = 8 h → short (fallback estimate).
        let d = try await store.addGame(GameDraft(title: "Unplayed Short", igdbID: 4, platformIDs: ["pc"],
                                                  owned: true))
        try await store.updateMetadata(gameID: d.gameID, MetadataPatch(ttbNormallyS: 8 * h))
        // Played with manual 220 h → over200.
        let e = try await store.addGame(GameDraft(title: "Marathon", igdbID: 6, platformIDs: ["pc"],
                                                  owned: true, played: true))
        try await store.setMyPlaytime(gameID: e.gameID, seconds: 220 * h)
        // Unplayed, no estimate → excluded from any band.
        _ = try await store.addGame(GameDraft(title: "No Data", igdbID: 5, platformIDs: ["pc"], owned: true))

        func ids(_ filter: LibraryFilter) async throws -> Set<Int64> {
            let rows = try await store.gamesOnce(filter: filter)
            return Set(rows.map(\.id))
        }
        func ids(_ buckets: Set<PlaytimeBucket>) async throws -> Set<Int64> {
            try await ids(LibraryFilter(playtimes: buckets, scope: .all))
        }

        #expect(try await ids([.short]) == [a.gameID, d.gameID])
        #expect(try await ids([.medium]) == [b.gameID])
        #expect(try await ids([.h80to100]) == [c.gameID])
        #expect(try await ids([.over200]) == [e.gameID])
        #expect(try await ids([.h40to60]).isEmpty)
        // OR within the kind.
        #expect(try await ids([.short, .h80to100]) == [a.gameID, c.gameID, d.gameID])
    }

    // MARK: - Band bounds through SQL at every edge

    @Test func playtimeBandEdgesThroughSQL() async throws {
        let store = try await TestDB.makeStore()
        // Seed one played game per edge value (in minutes, so 39 h 59 m is exact).
        // (label, seconds, expected band)
        let cases: [(String, Int, PlaytimeBucket)] = [
            ("e1", 39 * h + 59 * 60, .medium),     // 39:59 → 10–40
            ("e2", 40 * h,           .h40to60),    // 40:00 → 40–60
            ("e3", 79 * h + 59 * 60, .h60to80),    // 79:59 → 60–80
            ("e4", 80 * h,           .h80to100),   // 80:00 → 80–100
            ("e5", 99 * h + 59 * 60, .h80to100),   // 99:59 → 80–100
            ("e6", 100 * h,          .h100to150),  // 100:00 → 100–150
            ("e7", 199 * h + 59 * 60, .h150to200), // 199:59 → 150–200
            ("e8", 200 * h,          .over200),    // 200:00 → over200
        ]
        var idByLabel: [String: Int64] = [:]
        for (i, c) in cases.enumerated() {
            let g = try await store.addGame(GameDraft(title: c.0, igdbID: Int64(100 + i),
                                                      platformIDs: ["pc"], owned: true, played: true))
            try await store.setMyPlaytime(gameID: g.gameID, seconds: c.1)
            idByLabel[c.0] = g.gameID
        }
        for c in cases {
            // Selecting exactly the expected band returns this game and none of the
            // other edge games (each edge value lands in exactly one band).
            let rows = try await store.gamesOnce(
                filter: LibraryFilter(playtimes: [c.2], scope: .all))
            let got = Set(rows.map(\.id))
            #expect(got.contains(idByLabel[c.0]!), "\(c.0) (\(c.1)s) should land in \(c.2)")
            for other in cases where other.0 != c.0 && other.2 != c.2 {
                #expect(!got.contains(idByLabel[other.0]!),
                        "\(other.0) must not appear in band \(c.2)")
            }
        }
    }

    // MARK: - "No Estimate" and the normally → hastily → completely fallback

    @Test func noEstimateAndTTBFallbackThroughSQL() async throws {
        let store = try await TestDB.makeStore()
        // Only a *completely* estimate (no normally, no playtime): must be banded by it.
        let onlyCompletely = try await store.addGame(GameDraft(title: "OnlyCompletely", igdbID: 1,
                                                               platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: onlyCompletely.gameID,
                                       MetadataPatch(ttbCompletelyS: 20 * h))   // → medium
        // Only a *hastily* estimate: banded by it.
        let onlyHastily = try await store.addGame(GameDraft(title: "OnlyHastily", igdbID: 2,
                                                            platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: onlyHastily.gameID,
                                       MetadataPatch(ttbHastilyS: 5 * h))        // → short
        // A *normally* estimate wins over the others when present.
        let normally = try await store.addGame(GameDraft(title: "Normally", igdbID: 3,
                                                         platformIDs: ["pc"], owned: true))
        try await store.updateMetadata(gameID: normally.gameID,
                                       MetadataPatch(ttbHastilyS: 5 * h, ttbNormallyS: 20 * h,
                                                     ttbCompletelyS: 90 * h))    // → medium (normally)
        // No info at all → No Estimate.
        let none1 = try await store.addGame(GameDraft(title: "NoneA", igdbID: 4,
                                                     platformIDs: ["pc"], owned: true))
        let none2 = try await store.addGame(GameDraft(title: "NoneB", igdbID: 5,
                                                     platformIDs: ["pc"], owned: true, played: true))

        func ids(_ filter: LibraryFilter) async throws -> Set<Int64> {
            Set(try await store.gamesOnce(filter: filter).map(\.id))
        }

        // Fallback: hastily/completely-only games are banded, not dropped.
        #expect(try await ids(LibraryFilter(playtimes: [.short], scope: .all))
                == [onlyHastily.gameID])
        #expect(try await ids(LibraryFilter(playtimes: [.medium], scope: .all))
                == [onlyCompletely.gameID, normally.gameID])

        // "No Estimate" alone: only the two games with no time info at all.
        #expect(try await ids(LibraryFilter(includeNoTimeEstimate: true, scope: .all))
                == [none1.gameID, none2.gameID])

        // Combined with a band (OR within the kind).
        #expect(try await ids(LibraryFilter(playtimes: [.short], includeNoTimeEstimate: true, scope: .all))
                == [onlyHastily.gameID, none1.gameID, none2.gameID])

        // Across kinds (AND): No Estimate AND scope Played → only the played none.
        #expect(try await ids(LibraryFilter(includeNoTimeEstimate: true, scope: .played))
                == [none2.gameID])
        // No Estimate AND scope Backlog (owned, not played) → only the unplayed none;
        // the estimate-bearing backlog games are excluded.
        #expect(try await ids(LibraryFilter(includeNoTimeEstimate: true, scope: .backlog))
                == [none1.gameID])
    }

    // MARK: - In-memory banding (PlaytimeBucket.contains) parity with the SQL

    @Test func bandingParityBetweenContainsAndSQL() async throws {
        let store = try await TestDB.makeStore()
        // A spread of effective playtimes (seconds) across every band boundary.
        let seconds = [1, 5, 10, 39, 40, 55, 60, 79, 80, 95, 100, 149, 150, 199, 200, 350].map { $0 * h }
        var idBySeconds: [Int: Int64] = [:]
        for (i, s) in seconds.enumerated() {
            let g = try await store.addGame(GameDraft(title: "P\(i)", igdbID: Int64(500 + i),
                                                      platformIDs: ["pc"], owned: true, played: true))
            try await store.setMyPlaytime(gameID: g.gameID, seconds: s)
            idBySeconds[s] = g.gameID
        }
        // For every band, the SQL result must equal the set the pure `contains` picks.
        for band in PlaytimeBucket.allCases {
            let sql = Set(try await store.gamesOnce(
                filter: LibraryFilter(playtimes: [band], scope: .all)).map(\.id))
            let expected = Set(seconds.filter { band.contains($0) }.map { idBySeconds[$0]! })
            #expect(sql == expected, "band \(band): SQL and PlaytimeBucket.contains disagree")
        }
    }

    // MARK: - Playtime sort uses effective, unknowns last both directions

    @Test func playtimeSortPutsUnknownsLastBothDirections() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", igdbID: 1, platformIDs: ["pc"], played: true))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 10 * h)
        let b = try await store.addGame(GameDraft(title: "B", igdbID: 2, platformIDs: ["pc"], played: true))
        try await store.setMyPlaytime(gameID: b.gameID, seconds: 50 * h)
        let unknown = try await store.addGame(GameDraft(title: "Z", igdbID: 3, platformIDs: ["pc"], played: true))

        let desc = try await store.gamesOnce(
            filter: LibraryFilter(scope: .all, sort: .playtime, ascending: false)).map(\.id)
        #expect(desc.last == unknown.gameID)       // unknown last
        #expect(desc.first == b.gameID)            // most played first

        let asc = try await store.gamesOnce(
            filter: LibraryFilter(scope: .all, sort: .playtime, ascending: true)).map(\.id)
        #expect(asc.last == unknown.gameID)        // unknown still last
        #expect(asc.first == a.gameID)
    }

    // MARK: - Stats aggregates

    @Test func libraryStatsAggregate() async throws {
        let store = try await TestDB.makeStore()
        let a = try await store.addGame(GameDraft(title: "Bloodborne", igdbID: 1, platformIDs: ["ps4"],
                                                  owned: true, played: true, tierID: 1))
        try await store.setMyPlaytime(gameID: a.gameID, seconds: 40 * h)
        _ = try await store.addGame(GameDraft(title: "Backlog Game", igdbID: 2, platformIDs: ["ps4"],
                                              owned: true))               // owned, unplayed → backlog
        _ = try await store.addGame(GameDraft(title: "Played Only", igdbID: 3, platformIDs: ["pc"],
                                              owned: false, played: true))

        let stats = try await store.libraryStats()
        #expect(stats.total == 3)
        #expect(stats.owned == 2)
        #expect(stats.played == 2)
        #expect(stats.backlog == 1)
        #expect(stats.totalPlaytimeSeconds == 40 * h)
        // Top platform is ps4 (2 games).
        #expect(stats.byPlatform.first?.platformID == "ps4")
        #expect(stats.byPlatform.first?.count == 2)
        // Tier S has 1 played game.
        #expect(stats.byTier.first { $0.letter == "S" }?.count == 1)
    }

    // MARK: - Derived-score line via the store

    @Test func scoreLinePlacedAndUnplaced() async throws {
        let db = try await TestDB.makeSeeded()
        let store = LibraryStore(db)
        let ranking = RankingStore(db)

        // Three games placed in S with explicit keys, one unplaced in A.
        let s1 = try await store.addGame(GameDraft(title: "S1", igdbID: 1, platformIDs: ["pc"], played: true, tierID: 1))
        let s2 = try await store.addGame(GameDraft(title: "S2", igdbID: 2, platformIDs: ["pc"], played: true, tierID: 1))
        let s3 = try await store.addGame(GameDraft(title: "S3", igdbID: 3, platformIDs: ["pc"], played: true, tierID: 1))
        // Place them via drag moves (assigns keys), top → bottom.
        try await ranking.move(gameID: s1.gameID, toTier: 1, atIndex: 0)
        try await ranking.move(gameID: s2.gameID, toTier: 1, atIndex: 1)
        try await ranking.move(gameID: s3.gameID, toTier: 1, atIndex: 2)

        let a1 = try await store.addGame(GameDraft(title: "A1", igdbID: 4, platformIDs: ["pc"], played: true, tierID: 2))

        let line1 = try #require(await ranking.scoreLine(for: s1.gameID))
        #expect(line1.isPlaced)
        #expect(line1.tierLetter == "S")
        #expect(line1.tierPosition == 1)
        #expect(line1.tierTotalPlaced == 3)
        #expect(line1.overallPosition == 1)
        #expect(line1.overallTotalPlaced == 3)
        // Top of a full band → 10.0
        #expect(line1.score.value == 10.0)

        let line3 = try #require(await ranking.scoreLine(for: s3.gameID))
        #expect(line3.tierPosition == 3)
        #expect(line3.overallPosition == 3)

        // Unplaced A game: approximate, no positions.
        let lineA = try #require(await ranking.scoreLine(for: a1.gameID))
        #expect(!lineA.isPlaced)
        #expect(lineA.tierLetter == "A")
        #expect(lineA.tierPosition == nil)
        #expect(lineA.score.isApproximate)

        // Unranked (played, no tier) → no line.
        let un = try await store.addGame(GameDraft(title: "U", igdbID: 9, platformIDs: ["pc"], played: true))
        #expect(await ranking.scoreLine(for: un.gameID) == nil)
    }
}
