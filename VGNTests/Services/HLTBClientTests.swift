import Foundation
import Testing
import GRDB
@testable import VGN

/// The live HLTB client (PLAN §5.3) driven entirely offline through the stub
/// transport + a `ManualClock`: discovery (success + failure), search success /
/// empty, every reject path (HTML/captcha, 403, 429, schema drift), the 180/30-day
/// cache TTLs (hit, negative, expiry, zero requests on re-run), and the budget/pacer.
@Suite struct HLTBClientTests {

    private func cacheStore() throws -> ImportResponseCacheStore {
        ImportResponseCacheStore(try AppDatabase.inMemory())
    }

    /// A transport pre-wired for discovery (homepage + app chunk) plus a search body.
    private func transport(searchFixture: String) throws -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(
            status: 200,
            body: try Fixtures.data("hltb-discovery-home.html"),
            headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200,
            body: try Fixtures.data("hltb-discovery-app.js"),
            headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/api/", .init(status: 200,
            body: try Fixtures.data(searchFixture),
            headers: ["Content-Type": "application/json"]))
        return t
    }

    // MARK: - Discovery + search

    @Test func discoversEndpointThenSearches() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        let client = HLTBClient(transport: t, cache: try cacheStore(), clock: RecordingImmediateClock())
        let results = try await client.search(title: "Bloodborne")
        #expect(results.first?.id == 2600)
        // Homepage + app chunk + search = 3 requests; the search hit /api/.
        #expect(t.requestCount == 3)
        #expect(t.requests.last?.url?.absoluteString == "https://howlongtobeat.com/api/seek/abcd12ef")
        #expect(t.requests.last?.httpMethod == "POST")
    }

    @Test func injectedDiscoverySkipsHomepageFetch() async throws {
        let t = StubHTTPTransport(defaultStub: .init(status: 200,
            body: try Fixtures.data("hltb-search-celeste.json"),
            headers: ["Content-Type": "application/json"]))
        let client = HLTBClient(transport: t, cache: try cacheStore(),
                                clock: RecordingImmediateClock(),
                                discovery: .init(searchPath: "api/s/", payloadKey: nil, payloadValue: nil))
        let results = try await client.search(title: "Celeste")
        #expect(results.first?.name == "Celeste")
        #expect(t.requestCount == 1)   // no discovery round-trips
    }

    @Test func emptyResultReturnsNoCandidates() async throws {
        let t = try transport(searchFixture: "hltb-search-empty.json")
        let client = HLTBClient(transport: t, cache: try cacheStore(), clock: RecordingImmediateClock())
        let results = try await client.search(title: "No Such Game 9999")
        #expect(results.isEmpty)
    }

    // MARK: - Reject paths (stop on first unexpected response)

    private func expectReject(_ reason: ImportRejectReason,
                              searchStub: StubHTTPTransport.Stub) async throws {
        let t = StubHTTPTransport(defaultStub: .init(status: 200,
            body: try Fixtures.data("hltb-discovery-home.html"), headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200,
            body: try Fixtures.data("hltb-discovery-app.js"), headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/api/", searchStub)
        let cache = try cacheStore()
        let client = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock())
        await #expect(throws: ImportError.self) { try await client.search(title: "Bloodborne") }
        // A redacted reject was recorded.
        let count = try await cache.rejectCount(source: HLTBSource.id)
        #expect(count == 1)
    }

    @Test func captchaHTMLIsRejected() async throws {
        try await expectReject(.loginPageOrHTML,
            searchStub: .init(status: 200, body: Data("<html><body>captcha</body></html>".utf8),
                              headers: ["Content-Type": "text/html"]))
    }

    @Test func forbiddenIsRejected() async throws {
        try await expectReject(.authChallenge, searchStub: .init(status: 403, body: Data("no".utf8)))
    }

    @Test func rateLimitedIsRejected() async throws {
        try await expectReject(.rateLimited(retryAfter: nil),
            searchStub: .init(status: 429, body: Data("slow down".utf8)))
    }

    @Test func schemaDriftIsRejected() async throws {
        try await expectReject(.schemaMismatch,
            searchStub: .init(status: 200, body: Data(#"{"unexpected":[]}"#.utf8),
                              headers: ["Content-Type": "application/json"]))
    }

    @Test func discoveryFailureIsRejected() async throws {
        // Homepage 500 → discovery cannot proceed → reject, no search sent.
        let t = StubHTTPTransport(defaultStub: .init(status: 500, body: Data()))
        let cache = try cacheStore()
        let client = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock())
        await #expect(throws: ImportError.self) { try await client.search(title: "Bloodborne") }
        #expect(try await cache.rejectCount(source: HLTBSource.id) == 1)
    }

    // MARK: - Cache TTLs

    @Test func cachedHitCostsZeroRequestsOnRerun() async throws {
        let cache = try cacheStore()
        let wall = Date(timeIntervalSince1970: 1_000_000)
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")

        let c1 = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: { wall })
        _ = try await c1.search(title: "Bloodborne")
        let firstCount = t.requestCount
        #expect(firstCount == 3)

        // A fresh client (new run) served entirely from cache: zero requests.
        let c2 = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: { wall })
        let results = try await c2.search(title: "Bloodborne")
        #expect(results.first?.id == 2600)
        #expect(t.requestCount == firstCount)          // no new requests
        #expect(await c2.fromCache == 1)
        #expect(await c2.fromNetwork == 0)
    }

    @Test func negativeResultIsCachedThenExpiresAfter30Days() async throws {
        let cache = try cacheStore()
        let base = Date(timeIntervalSince1970: 2_000_000)
        let t = try transport(searchFixture: "hltb-search-empty.json")

        let c1 = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: { base })
        _ = try await c1.search(title: "Ghost Game")
        let afterFirst = t.requestCount

        // Within 30 days → served from cache (zero requests).
        let within = base.addingTimeInterval(20 * 24 * 3600)
        let c2 = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: { within })
        _ = try await c2.search(title: "Ghost Game")
        #expect(t.requestCount == afterFirst)

        // Past 30 days → the negative entry expired; it queries again.
        let beyond = base.addingTimeInterval(60 * 24 * 3600)
        let c3 = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: { beyond })
        _ = try await c3.search(title: "Ghost Game")
        #expect(t.requestCount > afterFirst)
    }

    @Test func hitTTLIsMuchLongerThanMiss() {
        #expect(ImportPolicy.hltbHitTTL == 180 * 24 * 3600)
        #expect(ImportPolicy.hltbMissTTL == 30 * 24 * 3600)
    }

    // MARK: - Budget + allow-list

    @Test func budgetIsEnforced() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        // Budget 2 → homepage + app chunk consume it; the search throws budgetExceeded.
        let pacing = ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: 2)
        let client = HLTBClient(transport: t, cache: try cacheStore(),
                                pacing: pacing, clock: RecordingImmediateClock())
        await #expect(throws: ImportError.self) { try await client.search(title: "Bloodborne") }
    }

    @Test func allowListRejectsOffHost() {
        #expect(HLTBClient.allowList.allows(URL(string: "https://howlongtobeat.com/api/s/")!))
        #expect(!HLTBClient.allowList.allows(URL(string: "https://evil.example.com/api/s/")!))
    }
}
