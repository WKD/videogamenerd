import Foundation
import Testing
import GRDB
@testable import VGN

/// The store/query/stats/export side of "To Revisit" (PLAN §4/§7b/§8): the flag is written
/// and read only through the ``PlayStatus`` mapping (raw `games.status` stays 'abandoned'),
/// every other status and un-play clear it, the completion filter treats Abandoned and To
/// Revisit as disjoint (SQL ≡ in-memory), Stats shows its own slice, and it round-trips
/// through the CSV export.
@Suite struct ToRevisitStoreTests {

    private func rawFlag(_ store: LibraryStore, _ id: Int64) async throws -> (status: String?, revisit: Int64) {
        try await store.dbWriter.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT status, revisit FROM games WHERE id = ?", arguments: [id])!
            return (r["status"], r["revisit"])
        }
    }

    // MARK: - Store mapping both ways

    @Test func setStatusToRevisitStoresAbandonedPlusFlagAndReadsBack() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "Drop", platformIDs: ["ps4"],
                                                  owned: true, played: true)).gameID
        try await store.setStatus([g], .toRevisit)

        // Raw DB keeps the legacy value; the flag carries the distinction.
        let raw = try await rawFlag(store, g)
        #expect(raw.status == "abandoned")
        #expect(raw.revisit == 1)
        // The store reads it back as the model status.
        #expect(try await store.gameDetail(id: g)?.status == .toRevisit)

        // And plain Abandoned is revisit = 0.
        try await store.setStatus([g], .abandoned)
        let raw2 = try await rawFlag(store, g)
        #expect(raw2.status == "abandoned")
        #expect(raw2.revisit == 0)
        #expect(try await store.gameDetail(id: g)?.status == .abandoned)
    }

    @Test func everyOtherStatusClearsTheFlag() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "G", platformIDs: ["ps4"],
                                                  owned: true, played: true)).gameID
        for setter in [PlayStatus.playing, .finished, .completed] {
            try await store.setStatus([g], .toRevisit)          // set the flag
            #expect(try await rawFlag(store, g).revisit == 1)
            try await store.setStatus([g], setter)              // switching clears it
            #expect(try await rawFlag(store, g).revisit == 0)
            #expect(try await store.gameDetail(id: g)?.status == setter)
        }
        // Clearing the status (nil) also clears the flag.
        try await store.setStatus([g], .toRevisit)
        try await store.setStatus([g], nil)
        #expect(try await rawFlag(store, g).revisit == 0)
    }

    @Test func markPlayedAsToRevisitAndUnplayClearsFlag() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "G", platformIDs: ["ps4"], owned: true)).gameID

        try await store.markPlayed([g], status: .toRevisit)
        #expect(try await store.gameDetail(id: g)?.status == .toRevisit)
        #expect(try await rawFlag(store, g).revisit == 1)

        // Un-playing clears status AND the flag (invariant 2).
        _ = try await store.setPlayed([g], false, confirmOrphanDelete: false)
        let raw = try await rawFlag(store, g)
        #expect(raw.status == nil)
        #expect(raw.revisit == 0)
        #expect(try await store.gameDetail(id: g)?.played == false)
    }

    @Test func addingAGameToRevisitWritesTheFlag() async throws {
        let store = try await TestDB.makeStore()
        let g = try await store.addGame(GameDraft(title: "New", platformIDs: ["ps4"],
                                                  owned: true, played: true, status: .toRevisit)).gameID
        #expect(try await rawFlag(store, g) == (status: "abandoned", revisit: 1))
        #expect(try await store.gameDetail(id: g)?.status == .toRevisit)
    }

    // MARK: - Filter disjointness: SQL ≡ in-memory

    @Test func completionFilterAbandonedAndToRevisitAreDisjoint() async throws {
        let store = try await TestDB.makeStore()
        let ab = try await store.addGame(GameDraft(title: "Abandoned", platformIDs: ["ps4"],
                                                   owned: true, played: true, status: .abandoned)).gameID
        let rv = try await store.addGame(GameDraft(title: "Revisit", platformIDs: ["ps4"],
                                                   owned: true, played: true, status: .toRevisit)).gameID
        let fin = try await store.addGame(GameDraft(title: "Finished", platformIDs: ["ps4"],
                                                    owned: true, played: true, status: .finished)).gameID

        // The already-loaded summaries (mapped) drive the in-memory evaluator.
        let allSummaries = try await store.gamesOnce(filter: LibraryFilter(scope: .all))

        func check(_ statuses: Set<PlayStatus>, expected: Set<Int64>) async throws {
            let f = LibraryFilter(statuses: statuses, scope: .all)
            let sql = Set(try await store.gamesOnce(filter: f).map(\.id))
            let mem = Set(LibraryFilterEvaluator.apply(f, to: allSummaries).map(\.id))
            #expect(sql == expected)
            #expect(sql == mem)          // SQL ≡ in-memory
        }

        try await check([.abandoned], expected: [ab])           // NOT the To Revisit game
        try await check([.toRevisit], expected: [rv])           // NOT the plain Abandoned game
        try await check([.abandoned, .toRevisit], expected: [ab, rv])
        try await check([.finished], expected: [fin])
    }

    // MARK: - Stats slice

    @Test func statsReportSplitsAbandonedAndToRevisit() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "A1", platformIDs: ["ps4"], owned: true, played: true, status: .abandoned))
        _ = try await store.addGame(GameDraft(title: "A2", platformIDs: ["ps4"], owned: true, played: true, status: .abandoned))
        _ = try await store.addGame(GameDraft(title: "R1", platformIDs: ["ps4"], owned: true, played: true, status: .toRevisit))

        let report = try await LibraryStatsStore(store.database).report(scope: .all)
        #expect(report.statusCounts.abandoned == 2)
        #expect(report.statusCounts.toRevisit == 1)
    }

    // MARK: - Export round-trip

    @Test func csvExportCarriesRevisitColumn() async throws {
        let store = try await TestDB.makeStore()
        _ = try await store.addGame(GameDraft(title: "RevisitMe", platformIDs: ["ps4"],
                                              owned: true, played: true, status: .toRevisit))
        _ = try await store.addGame(GameDraft(title: "DoneWithIt", platformIDs: ["ps4"],
                                              owned: true, played: true, status: .abandoned))

        let csv = try await LibraryExporter(store.database).exportCSV()
        let rows = csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        let header = rows[0]
        let statusCol = try #require(header.firstIndex(of: "status"))
        let revisitCol = try #require(header.firstIndex(of: "revisit"))

        func field(_ title: String, _ col: Int) -> String? {
            rows.first { $0.first == title }?[col]
        }
        // Both rows carry the legacy 'abandoned' status; the revisit column distinguishes them.
        #expect(field("RevisitMe", statusCol) == "abandoned")
        #expect(field("RevisitMe", revisitCol) == "yes")
        #expect(field("DoneWithIt", statusCol) == "abandoned")
        #expect(field("DoneWithIt", revisitCol) == "no")
    }
}
