import Foundation
import Testing
import GRDB
@testable import VGN

/// The query side of "Holds up today?" (PLAN §7b/§8): the Holds Up filter facet and the
/// "Needs a 'Holds Up' Rating" scope compile to SQL that is exactly the in-memory evaluator
/// (SQL ≡ in-memory), the sidebar count ≡ the scoped list, rating a game drops it from the
/// list live, the facet composes with others, and Stats counts the four slices.
@Suite struct HoldsUpQueryTests {

    /// A library with every state: holds up / of its time / too archaic / unrated (played),
    /// plus two unplayed games (never "unrated" for this mark).
    private func seeded() async throws -> (LibraryStore, [String: Int64]) {
        let store = try await TestDB.makeStore()
        var ids: [String: Int64] = [:]
        for (title, played) in [("Holds", true), ("Dated", true), ("Archaic", true),
                                ("Unrated A", true), ("Unrated B", true), ("Backlog", false),
                                ("Backlog 2", false)] {
            ids[title] = try await store.addGame(GameDraft(
                title: title, year: 1990, platformIDs: ["ps4"], owned: true, played: played)).gameID
        }
        try await store.setHoldsUp(.holdsUp, for: [ids["Holds"]!])
        try await store.setHoldsUp(.ofItsTime, for: [ids["Dated"]!])
        try await store.setHoldsUp(.tooArchaic, for: [ids["Archaic"]!])
        return (store, ids)
    }

    @Test func facetSQLMatchesInMemoryForEveryCombination() async throws {
        let (store, _) = try await seeded()
        let all = try await store.gamesOnce(filter: LibraryFilter(scope: .all))
        let values = HoldsUp.allCases
        // Every subset of the three marks × Unrated on/off (16 combinations), in two scopes.
        for mask in 0..<(1 << values.count) {
            let set = Set(values.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for unrated in [false, true] {
                for scope in [SidebarSelection.all, .played, .needsHoldsUpRating] {
                    let f = LibraryFilter(holdsUp: set, includeHoldsUpUnrated: unrated, scope: scope)
                    let sql = Set(try await store.gamesOnce(filter: f).map(\.id))
                    let mem = Set(LibraryFilterEvaluator.apply(f, to: all).map(\.id))
                    #expect(sql == mem, "facet \(set) unrated=\(unrated) scope=\(scope.id)")
                }
            }
        }
    }

    @Test func facetValuesSelectExactlyTheirGames() async throws {
        let (store, ids) = try await seeded()
        func titles(_ f: LibraryFilter) async throws -> Set<String> {
            let byID = Dictionary(uniqueKeysWithValues: ids.map { ($1, $0) })
            return Set(try await store.gamesOnce(filter: f).compactMap { byID[$0.id] })
        }
        #expect(try await titles(LibraryFilter(holdsUp: [.tooArchaic])) == ["Archaic"])
        #expect(try await titles(LibraryFilter(holdsUp: [.holdsUp, .ofItsTime])) == ["Holds", "Dated"])
        // Unrated = played with no mark — unplayed games are NOT unrated.
        #expect(try await titles(LibraryFilter(includeHoldsUpUnrated: true)) == ["Unrated A", "Unrated B"])
        // Composable: AND across kinds (Holds Up ∧ Status ▸ Not Played ⇒ nothing).
        #expect(try await titles(LibraryFilter(includeNotPlayed: true, holdsUp: [.holdsUp])).isEmpty)
    }

    @Test func sidebarCountEqualsTheScopedListAndRatingLeavesIt() async throws {
        let (store, ids) = try await seeded()
        func count() async throws -> Int {
            try await store.dbWriter.read { db in try LibraryQuery.fetchNeedsHoldsUpRatingCount(db) }
        }
        func list() async throws -> Set<Int64> {
            Set(try await store.gamesOnce(filter: LibraryFilter(scope: .needsHoldsUpRating)).map(\.id))
        }
        #expect(try await count() == 2)
        #expect(try await list() == [ids["Unrated A"]!, ids["Unrated B"]!])

        // Rating one removes it from the list and the count at once.
        try await store.setHoldsUp(.ofItsTime, for: [ids["Unrated A"]!])
        #expect(try await count() == 1)
        #expect(try await list() == [ids["Unrated B"]!])
        // Marking a backlog game played adds it (a newly played game needs a rating)…
        try await store.setPlayed([ids["Backlog"]!], true)
        #expect(try await count() == 2)
        // …and clearing a mark puts a game back.
        try await store.setHoldsUp(nil, for: [ids["Holds"]!])
        #expect(try await count() == 3)
        #expect(try await list().count == 3)
    }

    /// The live sidebar observation re-emits when a game is rated (no timer, same stream).
    @Test(.timeLimit(.minutes(1)))
    func liveCountFollowsARating() async throws {
        let (store, ids) = try await seeded()
        let source = GRDBLibraryDataSource(store: store)
        var iterator = source.sidebarCounts(pace: .default, style: .default).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.needsHoldsUpRating == 2)
        try await store.setHoldsUp(.holdsUp, for: [ids["Unrated A"]!, ids["Unrated B"]!])
        var latest = first
        while let next = await iterator.next() {
            latest = next
            if next.needsHoldsUpRating == 0 { break }
        }
        #expect(latest?.needsHoldsUpRating == 0)
    }

    @Test func statsCountsTheFourSlicesOverPlayedGames() async throws {
        let (store, _) = try await seeded()
        let report = try await LibraryStatsStore(store.database).report(scope: .all)
        #expect(report.holdsUpCounts == .init(holdsUp: 1, ofItsTime: 1, tooArchaic: 1, unrated: 2))
        let h = report.holdsUpCounts
        #expect(h.holdsUp + h.ofItsTime + h.tooArchaic + h.unrated == report.playedGames)
    }
}
