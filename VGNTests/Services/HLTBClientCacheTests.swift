import Foundation
import Testing
import GRDB
@testable import VGN

/// The HLTB client's caching surface added in wave 20 (PLAN §5.3, D1): the id-keyed
/// entry (`id:<hltbID>`), the freshness policies (cacheFirst — also every Refresh since wave 21 —
/// / bypassOne), and `cacheAge` for the "from cache, N h old" caption — all offline through
/// the stub transport + an injected wall clock.
@Suite struct HLTBClientCacheTests {

    private func cacheStore() throws -> ImportResponseCacheStore {
        ImportResponseCacheStore(try AppDatabase.inMemory())
    }

    private func transport(searchFixture: String) throws -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(
            status: 200, body: try Fixtures.data("hltb-discovery-home.html"),
            headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200,
            body: try Fixtures.data("hltb-discovery-app.js"),
            headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/init", .init(status: 200,
            body: try Fixtures.data("hltb-init.json"),
            headers: ["Content-Type": "application/json"]))
        t.on(urlContains: "/api/", .init(status: 200,
            body: try Fixtures.data(searchFixture),
            headers: ["Content-Type": "application/json"]))
        return t
    }

    private func client(_ t: StubHTTPTransport, _ cache: ImportResponseCacheStore,
                        wall: @escaping @Sendable () -> Date) -> HLTBClient {
        HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock(), wallClock: wall)
    }

    // MARK: - id-keyed cache

    @Test func rememberChosenIsReadBackByIDWithoutRequests() async throws {
        let t = try transport(searchFixture: "hltb-search-empty.json")
        let cache = try cacheStore()
        let c = client(t, cache, wall: { Date(timeIntervalSince1970: 1_000_000) })
        let candidate = HLTBCandidate(id: 21262, name: "Bloodborne", releaseYear: 2015,
                                      mainSeconds: 115887, platforms: ["PlayStation 4"])
        await c.rememberChosen(candidate)
        let before = t.requestCount
        let read = await c.linkedCandidate(hltbID: 21262)
        #expect(read == candidate)
        #expect(t.requestCount == before)   // zero requests to read the id-key
    }

    /// A mutable wall clock for a single client across two instants.
    private final class Wall: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ d: Date) { date = d }
        var now: Date { lock.withLock { date } }
        func advance(_ dt: TimeInterval) { lock.withLock { date += dt } }
    }

    @Test func linkedCandidateExpiresWithTheHitTTL() async throws {
        let t = try transport(searchFixture: "hltb-search-empty.json")
        let cache = try cacheStore()
        let wall = Wall(Date(timeIntervalSince1970: 1_000_000))
        let c = client(t, cache, wall: { wall.now })
        await c.rememberChosen(HLTBCandidate(id: 7, name: "X"))
        wall.advance(200 * 24 * 3600)   // past 180 d
        #expect(await c.linkedCandidate(hltbID: 7) == nil)
    }

    // MARK: - Freshness policies

    @Test func ambiguousReplyIsCachedTooSoThePickerCostsNothingLater() async throws {
        // A multi-candidate ("ambiguous") reply is a normal valid reply → cached.
        let t = try transport(searchFixture: "hltb-search-celeste.json")
        let cache = try cacheStore()
        let wall = Date(timeIntervalSince1970: 3_000_000)
        _ = try await client(t, cache, wall: { wall }).search(title: "Celeste")
        let after = t.requestCount
        let c2 = client(t, cache, wall: { wall })
        let again = try await c2.search(title: "Celeste")
        #expect(again.count > 1)
        #expect(t.requestCount == after)        // served from cache
        #expect(await c2.fromCache == 1)
    }

    /// Wave 21 (D3): there is no 24 h "refresh floor" any more — a Refresh uses `.cacheFirst`
    /// and serves any valid cached reply inside its TTL (here 100 days old, found → 180 d) at
    /// zero requests; only past the TTL does it go to the network.
    @Test func refreshServesAnyValidCachedReplyWithinItsTTL() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        let cache = try cacheStore()
        let base = Date(timeIntervalSince1970: 5_000_000)
        _ = try await client(t, cache, wall: { base }).search(title: "Bloodborne")
        let afterFirst = t.requestCount

        // 100 days later (inside the 180 d hit TTL), a Refresh is served from cache.
        let later = base.addingTimeInterval(100 * 24 * 3600)
        let c2 = client(t, cache, wall: { later })
        _ = try await c2.search(title: "Bloodborne", policy: .cacheFirst)
        #expect(t.requestCount == afterFirst)
        #expect(await c2.fromCache == 1)
        #expect(await c2.requestTally() == HLTBRequestTally(fromCache: 1, fromNetwork: 0))

        // Past the 180 d TTL the entry is stale → the network (paced).
        let expired = base.addingTimeInterval(181 * 24 * 3600)
        let c3 = client(t, cache, wall: { expired })
        _ = try await c3.search(title: "Bloodborne", policy: .cacheFirst)
        #expect(t.requestCount > afterFirst)
        #expect(await c3.fromNetwork == 1)
    }

    /// The fill service's cache pass reads a valid entry without a request, and says nil
    /// for an uncached title (wave 21 D3).
    @Test func cachedCandidatesNeverRequests() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        let cache = try cacheStore()
        let base = Date(timeIntervalSince1970: 5_500_000)
        _ = try await client(t, cache, wall: { base }).search(title: "Bloodborne")
        let afterFirst = t.requestCount
        let c2 = client(t, cache, wall: { base.addingTimeInterval(90 * 24 * 3600) })
        let hit = await c2.cachedCandidates(title: "Bloodborne")
        #expect(hit?.isEmpty == false)
        #expect(await c2.cachedCandidates(title: "Never Searched") == nil)
        #expect(t.requestCount == afterFirst)
    }

    @Test func bypassOneIgnoresAFreshEntry() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        let cache = try cacheStore()
        let wall = Date(timeIntervalSince1970: 6_000_000)
        _ = try await client(t, cache, wall: { wall }).search(title: "Bloodborne")
        let afterFirst = t.requestCount
        let c2 = client(t, cache, wall: { wall })
        _ = try await c2.search(title: "Bloodborne", policy: .bypassOne)
        #expect(t.requestCount > afterFirst)     // one bypassing request
        #expect(await c2.fromNetwork == 1)
    }

    // MARK: - cacheAge

    @Test func cacheAgeReportsTheEntryAge() async throws {
        let t = try transport(searchFixture: "hltb-search-bloodborne.json")
        let cache = try cacheStore()
        let base = Date(timeIntervalSince1970: 7_000_000)
        _ = try await client(t, cache, wall: { base }).search(title: "Bloodborne")
        let c2 = client(t, cache, wall: { base })
        let age = try #require(await c2.cacheAge(title: "Bloodborne", now: base.addingTimeInterval(3 * 3600)))
        #expect(abs(age - 10800) < 1)
        #expect(await c2.cacheAge(title: "Never Searched", now: base) == nil)
    }
}
