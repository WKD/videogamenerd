import Foundation
import Testing
import GRDB
@testable import VGN

/// Wave 21 lane B, end to end through the REAL ``HLTBClient`` + ``ImportResponseCacheStore``
/// (stub transport, no network): an inspector **Refresh** serves the owner's cached replies
/// (no 24 h floor any more, D3), re-scores them with the order-free matcher (D2) and re-maps
/// them with the Main-Story rule (D1) — **zero requests**. "Ask HowLongToBeat Again" is the
/// one explicit bypass. `@MainActor` + GRDB ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct HLTBRefreshFromCacheTests {

    nonisolated private static let beastWithin = "The Beast Within: A Gabriel Knight Mystery"

    /// A transport whose every answer is a valid (empty) search envelope — it only exists to
    /// count requests; the tests assert it is never reached (or reached once, for the bypass).
    private func transport() throws -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(
            status: 200, body: try Fixtures.data("hltb-discovery-home.html"),
            headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200, body: try Fixtures.data("hltb-discovery-app.js"),
                                           headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/init", .init(status: 200, body: try Fixtures.data("hltb-init.json"),
                                         headers: ["Content-Type": "application/json"]))
        t.on(urlContains: "/api/", .init(status: 200, body: try Fixtures.data("hltb-link-akira.json"),
                                         headers: ["Content-Type": "application/json"]))
        return t
    }

    /// Seed a cached search reply `daysOld` days old (well past the removed 24 h floor).
    private func seedCache(_ cache: ImportResponseCacheStore, title: String, fixture: String,
                           daysOld: Double) async throws {
        let body = try Fixtures.data(fixture)
        let count = try HLTBEndpoint.parseCandidates(body).count
        let fetchedAt = Date().addingTimeInterval(-daysOld * 86_400)
        let ttl = count > 0 ? ImportPolicy.hltbHitTTL : ImportPolicy.hltbMissTTL
        try await cache.store(ImportCacheRecord(
            source: HLTBSource.id, key: HLTBClient.cacheKey(title: title), endpoint: HLTBClient.searchEndpoint,
            paramsJSON: "{}", fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ttl),
            status: 200, body: body, itemCount: count, schemaVersion: 1))
    }

    private func presenter(_ db: AppDatabase, _ t: StubHTTPTransport) -> (HLTBFetchPresenter, LibraryViewModel) {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
        let p = HLTBFetchPresenter(store: LibraryStore(db), makeSearch: {
            HLTBClient(transport: t, cache: ImportResponseCacheStore(db), clock: RecordingImmediateClock())
        })
        p.library = vm
        return (p, vm)
    }

    private func waitDone(_ p: HLTBFetchPresenter) async {
        for _ in 0..<20_000 where p.isFetchingOne { await Task.yield() }
    }

    @Test(.timeLimit(.minutes(1)))
    func akiraRefreshFromCacheMeasuresTheGameWithZeroRequests() async throws {
        let db = try AppDatabase.inMemory()
        // The owner's row: linked, hltb-sourced, rushed only (the pre-wave-21 mapping).
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, year, played, ttb_hastily_s, ttb_source, hltb_id)
                VALUES (1, 'Akira', 1988, 1, 8070, 'hltb', 29582)
                """)
        }
        let cache = ImportResponseCacheStore(db)
        try await seedCache(cache, title: "Akira", fixture: "hltb-link-akira.json", daysOld: 40)
        let t = try transport()
        let (p, vm) = presenter(db, t)
        _ = vm

        p.refreshOne(gameID: 1)
        await waitDone(p)

        #expect(t.requestCount == 0)   // served from the 40-day-old cache — no floor
        let d = try await LibraryStore(db).gameDetail(id: 1)
        #expect(d?.ttbNormallyS == 8070 && d?.ttbHastilyS == 8070 && d?.ttbCompletelyS == nil)
        #expect(d?.ttbSource == "hltb" && d?.hltbID == 29582)
        let evening = try await LibraryStore(db).gamesOnce(filter: LibraryFilter(scope: .length(.evening)))
        #expect(evening.contains { $0.id == 1 })
    }

    @Test(.timeLimit(.minutes(1)))
    func beastWithinRefreshLinksGabrielKnightIIFromTheCache() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (1, ?, 1995, 1)",
                           arguments: [Self.beastWithin])
        }
        let cache = ImportResponseCacheStore(db)
        // The owner's cache: rung 1 (full title) → 0 results; "the beast within" → GK2 + Slain.
        try await seedCache(cache, title: Self.beastWithin, fixture: "hltb-search-empty.json", daysOld: 3)
        try await seedCache(cache, title: "The Beast Within", fixture: "hltb-link-beast-within.json", daysOld: 3)
        let t = try transport()
        let (p, vm) = presenter(db, t)
        _ = vm

        p.refreshOne(gameID: 1)
        await waitDone(p)

        #expect(t.requestCount == 0)   // the cache pass found the answer on rung 3
        #expect(p.picker == nil)       // confident — no picker needed
        let d = try await LibraryStore(db).gameDetail(id: 1)
        #expect(d?.hltbID == 3811)
        #expect(d?.ttbHastilyS == 57600 && d?.ttbNormallyS == 68400 && d?.ttbCompletelyS == 79200)
    }

    @Test(.timeLimit(.minutes(1)))
    func askHowLongToBeatAgainIsTheOneBypass() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (1, 'Akira', 1988, 1)")
        }
        let cache = ImportResponseCacheStore(db)
        try await seedCache(cache, title: "Akira", fixture: "hltb-link-akira.json", daysOld: 2)
        let t = try transport()
        let (p, vm) = presenter(db, t)
        _ = vm

        p.askAgainOne(gameID: 1)
        await waitDone(p)

        #expect(t.requestCount > 0)    // bypassed the valid cache for this one game
        let d = try await LibraryStore(db).gameDetail(id: 1)
        #expect(d?.ttbNormallyS == 8070 && d?.hltbID == 29582)
    }

    /// The bulk summary separates "no HLTB entry" from "needs your pick" (D2c) and notes the
    /// Main-Story-only games (D1).
    @Test(.timeLimit(.minutes(1)))
    func bulkSummarySeparatesNoEntryFromNeedsYourPick() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (1, 'Akira', 1988, 1)")
            try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (2, 'Zzyzx Quest', 2000, 1)")
            try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (3, 'Resident Evil', 1996, 1)")
        }
        let fake = FakeHLTBSearch(byTitle: [
            "Akira": [HLTBCandidate(id: 29582, name: "Akira", releaseYear: 1988, mainSeconds: 8070)],
            "Zzyzx Quest": [HLTBCandidate(id: 5, name: "Totally Different Game", releaseYear: 2000, mainSeconds: 60)],
            "Resident Evil": [HLTBCandidate(id: 6, name: "Resident Evil 2", releaseYear: 1998, mainSeconds: 60)],
        ])
        let model = HLTBBulkFetchModel(store: LibraryStore(db), makeSearch: { fake }, mode: .fillGaps)
        model.start(gameIDs: [1, 2, 3])
        for _ in 0..<20_000 where model.phase == .running { await Task.yield() }

        #expect(model.phase == .finished)
        #expect(model.summaryLine.hasPrefix("1 filled · 1 needs your pick · 1 no HLTB entry"))
        #expect(model.mainStoryNote == "1 game: Main+Extra not on HowLongToBeat — main story used.")
        #expect(model.ambiguous.map(\.gameID) == [3])
    }

    @Test func originNoteSaysFromCacheWithTheAge() async throws {
        #expect(HLTBFetchPresenter.cacheAgeText(3 * 3600) == "less than a day")
        #expect(HLTBFetchPresenter.cacheAgeText(86_400 * 1.5) == "1 day")
        #expect(HLTBFetchPresenter.cacheAgeText(86_400 * 12.2) == "12 days")
    }
}
