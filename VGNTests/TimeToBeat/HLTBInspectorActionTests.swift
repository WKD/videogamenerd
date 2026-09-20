import Foundation
import Testing
import GRDB
@testable import VGN

/// The inspector's single per-game HowLongToBeat action (wave 19 / D6). There is exactly ONE
/// action — always "Refresh from HowLongToBeat" — and it always routes to **replace** mode
/// (`HLTBFetchPresenter.refreshOne`), for every state a game can be in: no estimates, partial,
/// full, flagged, or already HLTB-sourced. Replace overwrites the three times (unlike the old
/// gap-only fetch), so these assert the value that only a replace produces. Reuses
/// ``FakeHLTBSearch`` (no network). `@MainActor` + GRDB ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct HLTBInspectorActionTests {

    private let h = 3600

    /// Seed one played game with the given (hastily, normally, completely) times and source.
    private func store(_ id: Int64, _ title: String,
                       _ r: Int?, _ m: Int?, _ c: Int?, source: String) async throws -> LibraryStore {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, played, ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                VALUES (?, ?, 1, ?, ?, ?, ?)
                """, arguments: [id, title, r, m, c, source])
        }
        return LibraryStore(db)
    }

    /// A confident HLTB match: main→hastily (1 h), main+extra→normally (5 h), completionist→completely (10 h).
    private func candidate(_ id: Int64, _ name: String) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, releaseYear: 2015,
                      mainSeconds: 1 * h, mainExtraSeconds: 5 * h, completionistSeconds: 10 * h)
    }

    /// The presenter needs a live ``LibraryViewModel`` — it holds it `weak`, so the caller must
    /// keep the returned model alive for the duration of the refresh.
    private func presenter(_ store: LibraryStore, _ fake: FakeHLTBSearch)
        -> (HLTBFetchPresenter, LibraryViewModel) {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
        let p = HLTBFetchPresenter(store: store, makeSearch: { fake })
        p.library = vm
        return (p, vm)
    }

    private func runRefresh(_ p: HLTBFetchPresenter, gameID: Int64) async {
        p.refreshOne(gameID: gameID)
        for _ in 0..<8000 where p.isFetchingOne { await Task.yield() }
    }

    /// A **full**, non-suspicious igdb game: the single action still fetches and REPLACES all
    /// three times (a fill-gaps action would have left them, having no gap to fill).
    @Test(.timeLimit(.minutes(1)))
    func refreshReplacesEvenWhenTimesAreFullAndNotFlagged() async throws {
        let store = try await store(1, "Full", 8 * h, 10 * h, 12 * h, source: "igdb")
        let (p, vm) = presenter(store, FakeHLTBSearch(byTitle: ["Full": [candidate(10, "Full")]]))
        _ = vm  // keep the weakly-held library alive
        await runRefresh(p, gameID: 1)

        let d = try await store.gameDetail(id: 1)
        #expect(d?.ttbHastilyS == 1 * h && d?.ttbNormallyS == 5 * h && d?.ttbCompletelyS == 10 * h)
        #expect(d?.ttbSource == "hltb")   // replace claimed HLTB as the source
        #expect(d?.hltbID == 10)
    }

    /// A **partial** game (a gap in the main story): replace overwrites the kept value too — a
    /// fill-gaps action would have preserved `normally == 10 h`.
    @Test(.timeLimit(.minutes(1)))
    func refreshReplacesRatherThanOnlyFillingAGap() async throws {
        let store = try await store(2, "Partial", nil, 10 * h, 12 * h, source: "igdb")
        let (p, vm) = presenter(store, FakeHLTBSearch(byTitle: ["Partial": [candidate(20, "Partial")]]))
        _ = vm  // keep the weakly-held library alive
        await runRefresh(p, gameID: 2)

        let d = try await store.gameDetail(id: 2)
        #expect(d?.ttbNormallyS == 5 * h)   // overwritten, not kept at 10 h
        #expect(d?.ttbHastilyS == 1 * h && d?.ttbCompletelyS == 10 * h)
        #expect(d?.ttbSource == "hltb")
    }

    /// A game with **no estimates at all**: replace writes all three.
    @Test(.timeLimit(.minutes(1)))
    func refreshFillsAGameWithNoEstimates() async throws {
        let store = try await store(3, "Blank", nil, nil, nil, source: "igdb")
        let (p, vm) = presenter(store, FakeHLTBSearch(byTitle: ["Blank": [candidate(30, "Blank")]]))
        _ = vm  // keep the weakly-held library alive
        await runRefresh(p, gameID: 3)

        let d = try await store.gameDetail(id: 3)
        #expect(d?.ttbHastilyS == 1 * h && d?.ttbNormallyS == 5 * h && d?.ttbCompletelyS == 10 * h)
        #expect(d?.ttbSource == "hltb")
    }

    /// An **already HLTB-sourced** game: the action is a re-check — it still searches and
    /// replaces (it is never suppressed just because the times already come from HLTB).
    @Test(.timeLimit(.minutes(1)))
    func refreshRechecksAnAlreadyHLTBSourcedGame() async throws {
        let store = try await store(4, "Recheck", 2 * h, 3 * h, 4 * h, source: "hltb")
        let fake = FakeHLTBSearch(byTitle: ["Recheck": [candidate(40, "Recheck")]])
        let (p, vm) = presenter(store, fake)
        _ = vm  // keep the weakly-held library alive
        await runRefresh(p, gameID: 4)

        #expect(fake.calls.contains("Recheck"))   // it queried HLTB again
        let d = try await store.gameDetail(id: 4)
        #expect(d?.ttbHastilyS == 1 * h && d?.ttbNormallyS == 5 * h && d?.ttbCompletelyS == 10 * h)
        #expect(d?.hltbID == 40)
    }

    /// A **flagged** (suspicious) game: replace clears the flag by making HLTB the reference.
    @Test(.timeLimit(.minutes(1)))
    func refreshClearsTheSuspiciousFlag() async throws {
        let store = try await store(5, "Flagged", 8 * h, 10 * h, 100 * h, source: "igdb")  // 100 ≥ 4×10
        #expect(try await store.suspiciousEstimateGameIDs() == [5])
        let (p, vm) = presenter(store, FakeHLTBSearch(byTitle: ["Flagged": [candidate(50, "Flagged")]]))
        _ = vm  // keep the weakly-held library alive
        await runRefresh(p, gameID: 5)

        let d = try await store.gameDetail(id: 5)
        #expect(d?.ttbSource == "hltb")
        #expect(try await store.suspiciousEstimateGameIDs().isEmpty)
    }
}
