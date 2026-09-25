import Foundation
import Testing
import GRDB
@testable import VGN

/// Wave 21 E — cached games are never blocked by a network failure. A bulk run (both
/// modes) applies everything the cache settles **before** any request; a sign-in (`/init`)
/// reject then stops the network part, and the summary reports what the cache kept. Real
/// ``HLTBClient`` + ``ImportResponseCacheStore`` over a stub transport — no network.
/// `@MainActor` + GRDB ⇒ `.serialized`.
@MainActor
@Suite(.serialized)
struct HLTBCacheBeforeNetworkTests {

    private let h = 3600

    /// `/init` answers an HTML page → schemaMismatch on `hltb/auth`; anything reaching the
    /// search would get a valid Bloodborne envelope (it must never be reached).
    private func initRejectingTransport() throws -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(
            status: 200, body: try Fixtures.data("hltb-discovery-home.html"), headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200, body: try Fixtures.data("hltb-discovery-app.js"),
                                           headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/init", .init(status: 200, body: Data("<html>changed</html>".utf8),
                                         headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/api/", .init(status: 200, body: try Fixtures.data("hltb-search-bloodborne.json"),
                                         headers: ["Content-Type": "application/json"]))
        return t
    }

    private func seedCache(_ cache: ImportResponseCacheStore, title: String, fixture: String) async throws {
        let body = try Fixtures.data(fixture)
        let count = try HLTBEndpoint.parseCandidates(body).count
        let fetchedAt = Date().addingTimeInterval(-5 * 86_400)
        try await cache.store(ImportCacheRecord(
            source: HLTBSource.id, key: HLTBClient.cacheKey(title: title), endpoint: HLTBClient.searchEndpoint,
            paramsJSON: "{}", fetchedAt: fetchedAt, expiresAt: fetchedAt.addingTimeInterval(ImportPolicy.hltbHitTTL),
            status: 200, body: body, itemCount: count, schemaVersion: 1))
    }

    /// Three games: 1 uncached ("Uncharted Nowhere"), 2 Akira + 3 Celeste cached (both
    /// confident matches).
    /// Each has an IGDB estimate, so `.replace` has something to overwrite; `.fillGaps` runs
    /// on the variant with no estimate.
    private func setup(withEstimates: Bool) async throws -> (AppDatabase, StubHTTPTransport) {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            for (id, title, year) in [(1, "Uncharted Nowhere", 2001), (2, "Akira", 1988), (3, "Celeste", 2018)] {
                if withEstimates {
                    try db.execute(sql: """
                        INSERT INTO games (id, title, year, played, ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source)
                        VALUES (?, ?, ?, 1, 3600, 36000, 360000, 'igdb')
                        """, arguments: [id, title, year])
                } else {
                    try db.execute(sql: "INSERT INTO games (id, title, year, played) VALUES (?, ?, ?, 1)",
                                   arguments: [id, title, year])
                }
            }
        }
        let cache = ImportResponseCacheStore(db)
        try await seedCache(cache, title: "Akira", fixture: "hltb-link-akira.json")
        try await seedCache(cache, title: "Celeste", fixture: "hltb-search-celeste.json")
        return (db, try initRejectingTransport())
    }

    private func run(_ model: HLTBBulkFetchModel, ids: [Int64]) async {
        model.start(gameIDs: ids)
        if model.needsConfirmation { model.confirmAndRun() }
        for _ in 0..<20_000 where model.phase == .running { await Task.yield() }
    }

    private func client(_ db: AppDatabase, _ t: StubHTTPTransport) -> @Sendable () -> any HLTBSearching {
        { HLTBClient(transport: t, cache: ImportResponseCacheStore(db), clock: RecordingImmediateClock()) }
    }

    @Test(.timeLimit(.minutes(1)))
    func replaceAppliesCachedGamesEvenThoughSignInIsRejected() async throws {
        let (db, t) = try await setup(withEstimates: true)
        let store = LibraryStore(db)
        let model = HLTBBulkFetchModel(store: store, makeSearch: client(db, t), mode: .replace)
        var captured: [Int64: HLTBTimeSnapshot] = [:]
        model.onReplaceFinished = { captured = $0 }
        // The uncached game comes FIRST — it must not block the cached ones.
        await run(model, ids: [1, 2, 3])

        #expect(model.phase == .stopped)
        #expect(model.updatedFromCache == 2)
        // Cached games replaced from the cache …
        let bb = try await store.gameDetail(id: 2)
        #expect(bb?.ttbSource == "hltb" && bb?.hltbID == 29582 && bb?.ttbNormallyS == 8070)
        let ce = try await store.gameDetail(id: 3)
        #expect(ce?.ttbSource == "hltb" && ce?.hltbID == 42818)
        // … the uncached one untouched.
        let un = try await store.gameDetail(id: 1)
        #expect(un?.ttbSource == "igdb" && un?.ttbNormallyS == 36000 && un?.hltbID == nil)
        // Only discovery + /init went out — never a search.
        #expect(t.requestCount == 3)
        #expect(!t.requests.contains { $0.httpMethod == "POST" })
        // The batch Undo still covers the cached replacements.
        #expect(Set(captured.keys) == [2, 3])
        #expect(model.summaryLine.hasPrefix("2 updated from cache · "))
        #expect(model.summaryLine.hasSuffix("stopped: HowLongToBeat changed its sign-in — nothing else was changed"))
        #expect(model.stoppedNote == "VGN stopped and made no further requests.")
        #expect(try await ImportResponseCacheStore(db).rejectCount(source: HLTBSource.id) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func fillGapsAppliesCachedGamesEvenThoughSignInIsRejected() async throws {
        let (db, t) = try await setup(withEstimates: false)
        let store = LibraryStore(db)
        let model = HLTBBulkFetchModel(store: store, makeSearch: client(db, t), mode: .fillGaps)
        await run(model, ids: [1, 2, 3])

        #expect(model.phase == .stopped)
        #expect(model.filled == 2 && model.updatedFromCache == 2)
        #expect(try await store.gameDetail(id: 2)?.ttbNormallyS == 8070)
        #expect(try await store.gameDetail(id: 3)?.ttbNormallyS == 52828)
        let un = try await store.gameDetail(id: 1)
        #expect(un?.ttbNormallyS == nil && un?.ttbSource == nil)
        #expect(!t.requests.contains { $0.httpMethod == "POST" })
        #expect(model.summaryLine
            == "2 updated from cache · 2 filled · 0 need your pick · 0 no HLTB entry · 2 from cache · 0 from network"
             + " · stopped: HowLongToBeat changed its sign-in — nothing else was changed")
    }

    @Test(.timeLimit(.minutes(1)))
    func fullyCachedRunMakesNoRequestAtAll() async throws {
        let (db, t) = try await setup(withEstimates: false)
        let model = HLTBBulkFetchModel(store: LibraryStore(db), makeSearch: client(db, t), mode: .fillGaps)
        await run(model, ids: [2, 3])
        #expect(model.phase == .finished)
        #expect(model.filled == 2)
        #expect(t.requestCount == 0)
        #expect(!model.summaryLine.contains("stopped"))
    }

    @Test(.timeLimit(.minutes(1)))
    func singleRefreshOfAnUncachedGameExplainsTheSignInStop() async throws {
        let (db, t) = try await setup(withEstimates: true)
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
        let p = HLTBFetchPresenter(store: LibraryStore(db), makeSearch: client(db, t))
        p.library = vm
        p.refreshOne(gameID: 1)
        for _ in 0..<20_000 where p.isFetchingOne { await Task.yield() }
        for _ in 0..<2_000 where vm.banner == nil { await Task.yield() }
        #expect(vm.banner?.message
            == "HowLongToBeat changed its sign-in. VGN stopped and made no further requests.")
        #expect(try await LibraryStore(db).gameDetail(id: 1)?.ttbSource == "igdb")
    }

    @Test(.timeLimit(.minutes(1)))
    func clearRejectLogIsAnExplicitPresenterAction() async throws {
        let db = try AppDatabase.inMemory()
        let cache = ImportResponseCacheStore(db)
        for _ in 0..<2 {
            try await cache.recordReject(ImportReject(
                source: HLTBSource.id, endpoint: HLTBClient.authEndpoint, status: 200,
                reason: .schemaMismatch, redactedExcerpt: "{}", receivedAt: importFixedNow))
        }
        try await cache.recordReject(ImportReject(
            source: ImportSourceID.gog, endpoint: "e", reason: .unknown, receivedAt: importFixedNow))
        let p = HLTBFetchPresenter(store: LibraryStore(db), makeSearch: { HLTBInertSearch() })
        await p.reloadRejectLogCount()
        #expect(p.rejectLogCount == 2)
        await p.clearRejectLog()
        #expect(p.rejectLogCount == 0)
        #expect(try await cache.rejectCount(source: HLTBSource.id) == 0)
        #expect(try await cache.rejectCount(source: ImportSourceID.gog) == 1)
    }
}
