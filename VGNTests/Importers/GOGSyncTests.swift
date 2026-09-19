import Foundation
import Testing
import GRDB
@testable import VGN

/// End-to-end GOG sync through ``GOGClient`` + ``GOGImporter`` + ``ImportSyncCoordinator``
/// on synthetic fixtures: happy path, zero-request second sync (cache), stop-on-reject
/// leaving the good cache intact, and budget exhaustion. ZERO live requests.
@Suite(.timeLimit(.minutes(1)))
struct GOGSyncTests {

    private static let fastPacing = ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: 15)

    private func makeImporter(transport: HTTPTransport, cache: ImportResponseCacheStore,
                              pacing: ImportPolicy.Pacing = fastPacing) -> GOGImporter {
        GOGImporter(auth: seededGOGAuth(transport: transport), transport: transport, cache: cache,
                    pacing: pacing, clock: SystemClock(), wallClock: { importFixedNow })
    }

    @Test func happyPathStagesAndSummarises() async throws {
        let transport = try gogHappyPathTransport()
        let db = try await ImportTestDB.makeSeeded()
        let cache = ImportResponseCacheStore(db)
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let matcher = FakeImportMatcher()

        let result = try await coordinator.run(makeImporter(transport: transport, cache: cache), matcher: matcher)

        // 5 network requests: userData + owned + 3 pages (token was already valid).
        #expect(transport.requestCount == 5)
        #expect(result.summary.fromNetwork == 5)
        #expect(result.summary.fromCache == 0)
        #expect(result.summary.budgetUsed == 5)
        #expect(result.summary.stagedTotal == 10)
        #expect(result.summary.newCount == 5)
        #expect(result.summary.ignoredCount == 5)
        #expect(result.summary.rejects.isEmpty)
        // The matcher was consulted for each of the 5 *New* titles.
        #expect(result.matches.count == 5)
        #expect(matcher.requests.count == 5)
        #expect(result.summary.networkSummaryLine == "0 from cache · 5 from network")
    }

    @Test func secondSyncMakesZeroRequests() async throws {
        let transport = try gogHappyPathTransport()
        let db = try await ImportTestDB.makeSeeded()
        let cache = ImportResponseCacheStore(db)
        let coordinator = ImportSyncCoordinator(staging: ImportStagingStore(db))
        let matcher = FakeImportMatcher()

        _ = try await coordinator.run(makeImporter(transport: transport, cache: cache), matcher: matcher)
        let afterFirst = transport.requestCount

        let second = try await coordinator.run(makeImporter(transport: transport, cache: cache), matcher: matcher)
        #expect(transport.requestCount == afterFirst)     // ZERO further transport calls
        #expect(second.summary.fromCache == 5)
        #expect(second.summary.fromNetwork == 0)
        #expect(second.summary.budgetUsed == 0)
        #expect(second.summary.stagedTotal == 10)         // nothing new proposed
    }

    @Test func stopsOnRejectAndLeavesGoodCacheIntact() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let cache = ImportResponseCacheStore(db)
        // A previously-cached good entry that the reject must NOT wipe.
        try await cache.store(ImportCacheRecord(
            source: ImportSourceID.gog, key: "user/data/games", endpoint: "e", paramsJSON: "{}",
            fetchedAt: importFixedNow, expiresAt: importFixedNow.addingTimeInterval(ImportPolicy.cacheTTL),
            status: 200, body: Data("{\"owned\":[1]}".utf8), itemCount: 1, schemaVersion: 1))

        // userData returns the HTML login page → the sync stops on the first call.
        let transport = StubHTTPTransport(defaultStub: .init(status: 200, body: Data("{}".utf8),
                                                             headers: ["Content-Type": "application/json"]))
        transport.on(urlContains: "userData.json",
                     .init(status: 200, body: try Fixtures.data("gog-login-page.html"),
                           headers: ["Content-Type": "text/html"]))
        let coordinator = ImportSyncCoordinator(staging: ImportStagingStore(db))

        var caught: ImportError?
        do {
            _ = try await coordinator.run(makeImporter(transport: transport, cache: cache), matcher: FakeImportMatcher())
        } catch let error as ImportError {
            caught = error
        }
        guard case .rejected(let reject) = caught else {
            Issue.record("expected .rejected, got \(String(describing: caught))"); return
        }
        #expect(reject.reason == .loginPageOrHTML)

        // userData was never cached; the earlier good owned-cache entry survives.
        let cachedKeys = try await db.dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM import_cache WHERE source='gog' ORDER BY key")
        }
        #expect(cachedKeys == ["user/data/games"])
        #expect(try await cache.rejectCount(source: ImportSourceID.gog) == 1)
    }

    @Test func budgetExhaustionAbortsSync() async throws {
        let transport = try gogHappyPathTransport()
        let db = try await ImportTestDB.makeSeeded()
        let cache = ImportResponseCacheStore(db)
        // Budget 2 < the 5 requests a cold sync needs → aborts, never "just continues".
        let importer = makeImporter(transport: transport, cache: cache,
                                    pacing: ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: 2))
        let coordinator = ImportSyncCoordinator(staging: ImportStagingStore(db))

        var caught: ImportError?
        do {
            _ = try await coordinator.run(importer, matcher: FakeImportMatcher())
        } catch let error as ImportError {
            caught = error
        }
        #expect(caught == .budgetExceeded(limit: 2))
        #expect(transport.requestCount == 2)   // stopped at the cap
    }
}
