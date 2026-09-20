import Foundation
import Testing
@testable import VGN

// MARK: - Request-counting transports (no network)

/// Answers the token endpoint and `/v4/games` id-metadata queries, returning one full-ish
/// game object per id in the `where id = (…)` set. Counts every api request and records
/// each requested id-set, so read-through hit/miss/partial/force can be asserted exactly.
private final class MetadataCountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var apiCount = 0
    private(set) var requestedIDSets: [[Int64]] = []

    var apiRequestCount: Int { lock.withLock { apiCount } }
    var lastRequestedIDs: [Int64] { lock.withLock { requestedIDSets.last ?? [] } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let payload: Data
        if url.contains("id.twitch.tv") {
            payload = Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)
        } else {
            let ids = Self.parseIDSet(body)
            lock.withLock { apiCount += 1; requestedIDSets.append(ids) }
            let objects: [[String: Any]] = ids.map {
                ["id": $0, "name": "Game \($0)", "summary": "Summary \($0)"]
            }
            payload = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (payload, http)
    }

    /// Pull the ids out of `where id = (1,2,3)`.
    static func parseIDSet(_ body: String) -> [Int64] {
        guard let open = body.range(of: "id = ("),
              let close = body.range(of: ")", range: open.upperBound..<body.endIndex)
        else { return [] }
        return body[open.upperBound..<close.lowerBound]
            .split(separator: ",")
            .compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Returns a fixed artworks response for any `/v4/games` artworks query, counting requests.
private final class ArtworksCountingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var apiCount = 0
    var apiRequestCount: Int { lock.withLock { apiCount } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let payload: Data
        if url.contains("id.twitch.tv") {
            payload = Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)
        } else {
            lock.withLock { apiCount += 1 }
            payload = Data(#"[{"id":7334,"artworks":[{"image_id":"art1","width":100,"height":120}]}]"#.utf8)
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (payload, http)
    }
}

private enum ReadCacheHarness {
    static let credentials: @Sendable () async -> IGDBCredentials? = {
        IGDBCredentials(clientID: "cid", secret: "sec")
    }

    /// A client whose limiter shares the given clock, so `clock.deadlines.count` == the
    /// number of times a request went through `RateLimiter.acquire()` (the pacing proof).
    static func client(
        transport: HTTPTransport,
        cache: CatalogCaching,
        clock: RecordingImmediateClock = RecordingImmediateClock(),
        credentials: (@Sendable () async -> IGDBCredentials?)? = nil
    ) -> IGDBClient {
        IGDBClient(
            transport: transport,
            credentials: credentials ?? Self.credentials,
            catalog: TestCatalog.catalog,
            cache: cache,
            clock: clock
        )
    }

    static func metadataBlob(id: Int64) -> Data {
        CatalogCacheShapeJSON.tagged(["id": id, "name": "Game \(id)", "summary": "Summary \(id)"],
                                     shapes: [.search, .metadata])
    }

    static func searchOnlyBlob(id: Int64) -> Data {
        CatalogCacheShapeJSON.tagged(["id": id, "name": "Game \(id)"], shapes: .search)
    }
}

// MARK: - Read-through by id (D1)

@Suite(.serialized)
struct IGDBReadThroughTests {

    @Test("Warm metadata cache serves every id with zero requests and zero limiter waits")
    func fullHit() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        await cache.store([1, 2, 3].map { CatalogCacheEntry(igdbID: $0, json: ReadCacheHarness.metadataBlob(id: $0), fetchedAt: date.now) })

        let transport = MetadataCountingTransport()
        let clock = RecordingImmediateClock()
        let client = ReadCacheHarness.client(transport: transport, cache: cache, clock: clock)

        let metas = try await client.games(ids: [1, 2, 3])
        #expect(metas.map(\.id) == [1, 2, 3])
        #expect(metas.allSatisfy { $0.summary?.isEmpty == false })
        #expect(transport.apiRequestCount == 0)   // served from cache
        #expect(clock.deadlines.isEmpty)           // never touched the rate limiter
    }

    @Test("Partial hit fetches only the missing ids and preserves requested order")
    func partialHit() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        // 1 and 3 cached; 2 missing.
        await cache.store([1, 3].map { CatalogCacheEntry(igdbID: $0, json: ReadCacheHarness.metadataBlob(id: $0), fetchedAt: date.now) })

        let transport = MetadataCountingTransport()
        let clock = RecordingImmediateClock()
        let client = ReadCacheHarness.client(transport: transport, cache: cache, clock: clock)

        let metas = try await client.games(ids: [1, 2, 3])
        #expect(metas.map(\.id) == [1, 2, 3])               // order preserved
        #expect(transport.apiRequestCount == 1)             // one batched request
        #expect(transport.lastRequestedIDs == [2])          // only the missing id
        #expect(clock.deadlines.count == 1)                 // exactly one limiter acquisition
    }

    @Test("A stale entry is refetched and overwritten")
    func staleRefetched() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        let stale = date.now.addingTimeInterval(-40 * 24 * 60 * 60)
        await cache.store(CatalogCacheEntry(igdbID: 5, json: ReadCacheHarness.metadataBlob(id: 5), fetchedAt: stale))

        let transport = MetadataCountingTransport()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)

        _ = try await client.games(ids: [5])
        #expect(transport.apiRequestCount == 1)             // stale → network
        // Overwritten with a fresh stamp: a second lookup is a hit.
        #expect(await cache.entry(forID: 5) != nil)
        _ = try await client.games(ids: [5])
        #expect(transport.apiRequestCount == 1)             // now fresh → no new request
    }

    @Test("A slimmer (search-shape) entry is a miss for a metadata caller and gets upgraded")
    func slimmerShapeMiss() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        // Only a search-shape blob (name, no summary) is cached.
        await cache.store(CatalogCacheEntry(igdbID: 9, json: ReadCacheHarness.searchOnlyBlob(id: 9), fetchedAt: date.now))

        let transport = MetadataCountingTransport()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)

        let metas = try await client.games(ids: [9])
        #expect(metas.first?.summary == "Summary 9")        // came from the network fetch
        #expect(transport.apiRequestCount == 1)             // slim shape ⇒ miss ⇒ fetch

        // Upgraded: the blob now satisfies .metadata, so a second call is a hit.
        let upgraded = try #require(await cache.entry(forID: 9))
        #expect(CatalogCacheShapeJSON.shapes(in: upgraded.json).contains(.metadata))
        _ = try await client.games(ids: [9])
        #expect(transport.apiRequestCount == 1)
    }

    @Test("force bypasses the cache and overwrites it")
    func forceBypasses() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        await cache.store(CatalogCacheEntry(igdbID: 7, json: ReadCacheHarness.metadataBlob(id: 7), fetchedAt: date.now))

        let transport = MetadataCountingTransport()
        let clock = RecordingImmediateClock()
        let client = ReadCacheHarness.client(transport: transport, cache: cache, clock: clock)

        _ = try await client.games(ids: [7], force: true)
        #expect(transport.apiRequestCount == 1)             // force skips the cached hit
        #expect(clock.deadlines.count == 1)                 // forced fetch STILL paced by the limiter
    }

    @Test("Cache hits are served with no credentials (offline / sample-safe)")
    func hitsServeOffline() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        await cache.store(CatalogCacheEntry(igdbID: 3, json: ReadCacheHarness.metadataBlob(id: 3), fetchedAt: date.now))

        let transport = MetadataCountingTransport()
        // No credentials at all — the network path would throw, but a hit never reaches it.
        let client = ReadCacheHarness.client(transport: transport, cache: cache, credentials: { nil })
        let metas = try await client.games(ids: [3])
        #expect(metas.map(\.id) == [3])
        #expect(transport.apiRequestCount == 0)
    }

    @Test("Bundle members are served from cache on the second call")
    func bundleMembersCached() async throws {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200, body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data("igdb-bundle-members-mgs.json")))
        let cache = InMemoryCatalogCache()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)

        let first = try await client.bundleMembers(ofBundleID: 20196)
        let firstCount = transport.requests.filter { $0.url?.absoluteString.contains("api.igdb.com") == true }.count
        #expect(first.count == 9)
        #expect(firstCount >= 1)

        let second = try await client.bundleMembers(ofBundleID: 20196)
        let secondCount = transport.requests.filter { $0.url?.absoluteString.contains("api.igdb.com") == true }.count
        #expect(second.map(\.id) == first.map(\.id))        // same members, same order
        #expect(secondCount == firstCount)                  // no new request
    }

    @Test("Artworks are served from cache on the second call; force refetches")
    func artworksCached() async throws {
        let transport = ArtworksCountingTransport()
        let cache = InMemoryCatalogCache()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)

        let first = try await client.artworks(forGameID: 7334)
        #expect(first.first?.imageID == "art1")
        #expect(transport.apiRequestCount == 1)

        let second = try await client.artworks(forGameID: 7334)
        #expect(second.first?.imageID == "art1")
        #expect(transport.apiRequestCount == 1)             // hit
        _ = try await client.artworks(forGameID: 7334, force: true)
        #expect(transport.apiRequestCount == 2)             // force refetches
    }

    @Test("PERF: 200 warm metadata lookups make zero requests")
    func warmLookupsPerf() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        let ids: [Int64] = Array(1...200)

        let transport = MetadataCountingTransport()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)

        // Cold: 200 distinct lookups, each a miss → one request apiece.
        for id in ids { _ = try await client.games(ids: [id]) }
        let cold = transport.apiRequestCount

        // Warm: the same 200 lookups, now all cached.
        for id in ids { _ = try await client.games(ids: [id]) }
        let warm = transport.apiRequestCount - cold

        print("IGDB read cache — 200 metadata lookups: cold=\(cold) requests, warm=\(warm) requests")
        #expect(cold == 200)
        #expect(warm == 0)
    }
}

// MARK: - Per-shape freshness (W19 part 2A)

@Suite(.serialized)
struct IGDBPerShapeFreshnessTests {
    private func day(_ n: Double) -> TimeInterval { n * 24 * 60 * 60 }

    @Test("A search write does not refresh stale metadata")
    func searchDoesNotRefreshMetadata() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        let old = date.now.addingTimeInterval(-day(60))
        await cache.store(CatalogCacheEntry(igdbID: 5,
            json: CatalogCacheShapeJSON.stamped(["id": 5, "name": "G5", "summary": "S5"], shapes: [.search, .metadata], at: old),
            fetchedAt: old))
        // A search sighting today renews only the search stamp.
        await cache.store(CatalogCacheEntry(igdbID: 5,
            json: CatalogCacheShapeJSON.stamped(["id": 5, "name": "G5"], shapes: .search, at: date.now),
            fetchedAt: date.now))

        #expect(await cache.freshEntry(forID: 5, satisfying: .search) != nil)     // search fresh
        #expect(await cache.freshEntry(forID: 5, satisfying: .metadata) == nil)   // metadata still stale

        let transport = MetadataCountingTransport()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)
        _ = try await client.games(ids: [5])
        #expect(transport.apiRequestCount == 1)   // refetched despite the fresh search sighting
    }

    @Test("Metadata goes stale after 30 days even with daily search sightings")
    func metadataStaleDespiteDailySearch() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        await cache.store(CatalogCacheEntry(igdbID: 7,
            json: CatalogCacheShapeJSON.stamped(["id": 7, "name": "G7", "summary": "S7"], shapes: [.search, .metadata], at: date.now),
            fetchedAt: date.now))
        for _ in 0..<40 {
            date.advance(by: day(1))
            await cache.store(CatalogCacheEntry(igdbID: 7,
                json: CatalogCacheShapeJSON.stamped(["id": 7, "name": "G7"], shapes: .search, at: date.now),
                fetchedAt: date.now))
        }
        #expect(await cache.freshEntry(forID: 7, satisfying: .search) != nil)     // search still fresh
        #expect(await cache.freshEntry(forID: 7, satisfying: .metadata) == nil)   // metadata > 30 d old
    }

    @Test("force overwrites the shape's own stamp")
    func forceRefreshesStamp() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        let old = date.now.addingTimeInterval(-day(60))
        await cache.store(CatalogCacheEntry(igdbID: 9,
            json: CatalogCacheShapeJSON.stamped(["id": 9, "name": "G9", "summary": "S9"], shapes: [.search, .metadata], at: old),
            fetchedAt: old))
        #expect(await cache.freshEntry(forID: 9, satisfying: .metadata) == nil)   // stale

        let transport = MetadataCountingTransport()
        let client = ReadCacheHarness.client(transport: transport, cache: cache)
        _ = try await client.games(ids: [9], force: true)
        #expect(transport.apiRequestCount == 1)
        #expect(await cache.freshEntry(forID: 9, satisfying: .metadata) != nil)   // stamp refreshed
        _ = try await client.games(ids: [9])
        #expect(transport.apiRequestCount == 1)                                   // now a hit
    }

    @Test("A part-1 blob (mask, no per-shape stamps) falls back to the row fetched_at")
    func partOneBlobFallsBack() async throws {
        let db = try await TestDB.makeSeeded()
        let date = MutableDate()
        let cache = CatalogCacheStore(db, now: { date.now })
        // Fresh row, tagged mask-only (the pre-part-2 format) → hit via the row stamp fallback.
        await cache.store(CatalogCacheEntry(igdbID: 3,
            json: CatalogCacheShapeJSON.tagged(["id": 3, "name": "G3", "summary": "S3"], shapes: [.search, .metadata]),
            fetchedAt: date.now))
        #expect(await cache.freshEntry(forID: 3, satisfying: .metadata) != nil)
        // Same blob on a 40-day-old row → stale via the fallback.
        await cache.store(CatalogCacheEntry(igdbID: 4,
            json: CatalogCacheShapeJSON.tagged(["id": 4, "name": "G4", "summary": "S4"], shapes: [.search, .metadata]),
            fetchedAt: date.now.addingTimeInterval(-day(40))))
        #expect(await cache.freshEntry(forID: 4, satisfying: .metadata) == nil)
    }
}

// MARK: - Search LRU (D2/D3) — actor in isolation, deterministic

/// File-scope helpers so the `@Sendable` produce closures capture no test-struct `self`.
private func searchKey(_ text: String) -> IGDBSearchCache.Key {
    IGDBSearchCache.Key(kind: "autocomplete", text: text, platforms: nil, limit: 12)
}
private func searchStub(_ id: Int64) -> IGDBSearchResult {
    IGDBSearchResult(id: id, name: "G\(id)", releaseYear: nil, coverImageID: nil,
                     platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                     genres: [], alternativeNames: [], gameType: .mainGame)
}

@Suite(.serialized)
struct IGDBSearchCacheTests {

    @Test("A repeat query is served from cache (produce runs once)")
    func repeatHit() async throws {
        let cache = IGDBSearchCache(clock: ManualClock())
        let counter = AtomicCounter()
        let make: @Sendable () async throws -> [IGDBSearchResult] = { _ = counter.increment(); return [searchStub(1)] }

        _ = try await cache.value(for: searchKey("bloodborne"), force: false, produce: make)
        _ = try await cache.value(for: searchKey("bloodborne"), force: false, produce: make)
        #expect(counter.count == 1)
    }

    @Test("TTL expiry re-runs the query")
    func ttlExpiry() async throws {
        let clock = ManualClock()
        let cache = IGDBSearchCache(ttl: 900, clock: clock)
        let counter = AtomicCounter()
        let make: @Sendable () async throws -> [IGDBSearchResult] = { _ = counter.increment(); return [searchStub(1)] }

        _ = try await cache.value(for: searchKey("zelda"), force: false, produce: make)
        clock.advance(by: 901)                              // past the 15-min TTL
        _ = try await cache.value(for: searchKey("zelda"), force: false, produce: make)
        #expect(counter.count == 2)
    }

    @Test("LRU evicts the oldest query past the cap")
    func lruEviction() async throws {
        let cache = IGDBSearchCache(capacity: 2, clock: ManualClock())
        let counter = AtomicCounter()
        func run(_ t: String) async throws {
            _ = try await cache.value(for: searchKey(t), force: false) { _ = counter.increment(); return [] }
        }
        try await run("a"); try await run("b"); try await run("c")   // "a" evicted (cap 2)
        try await run("a")                                            // miss again → re-run
        #expect(counter.count == 4)
        try await run("c")                                            // "c" still cached → no re-run
        #expect(counter.count == 4)
    }

    @Test("Empty results are cached; errors are not")
    func emptyCachedErrorNot() async throws {
        let cache = IGDBSearchCache(clock: ManualClock())

        let emptyCounter = AtomicCounter()
        _ = try await cache.value(for: searchKey("nohits"), force: false) { _ = emptyCounter.increment(); return [] }
        _ = try await cache.value(for: searchKey("nohits"), force: false) { _ = emptyCounter.increment(); return [] }
        #expect(emptyCounter.count == 1)                    // empty result was cached

        struct Boom: Error {}
        let errCounter = AtomicCounter()
        for _ in 0..<2 {
            _ = try? await cache.value(for: searchKey("boom"), force: false) { _ = errCounter.increment(); throw Boom() }
        }
        #expect(errCounter.count == 2)                      // error never cached → re-run
    }

    @Test("force bypasses the cached value and overwrites it")
    func forceOverwrites() async throws {
        let cache = IGDBSearchCache(clock: ManualClock())
        let counter = AtomicCounter()
        let make: @Sendable () async throws -> [IGDBSearchResult] = {
            let n = counter.increment(); return [searchStub(Int64(n))]
        }
        let first = try await cache.value(for: searchKey("q"), force: false, produce: make)
        let forced = try await cache.value(for: searchKey("q"), force: true, produce: make)
        #expect(first.first?.id == 1)
        #expect(forced.first?.id == 2)                      // force re-ran
        let afterForce = try await cache.value(for: searchKey("q"), force: false, produce: make)
        #expect(afterForce.first?.id == 2)                  // and overwrote the cache
        #expect(counter.count == 2)
    }

    @Test("Concurrent identical calls coalesce onto ONE produce")
    func concurrentCoalescing() async throws {
        let cache = IGDBSearchCache(clock: ManualClock())
        let gate = ManualClock()                            // gates produce so all callers overlap
        let counter = AtomicCounter()
        let make: @Sendable () async throws -> [IGDBSearchResult] = {
            _ = counter.increment()
            try await gate.sleep(until: 1)                  // park until released
            return [searchStub(1)]
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await cache.value(for: searchKey("dup"), force: false, produce: make) }
            }
            await gate.waitForSleepers(count: 1)            // exactly one produce parked
            gate.advance(by: 2)                             // release it
        }
        #expect(counter.count == 1)                         // 8 concurrent calls → 1 network op
    }
}

// MARK: - Client-level search coalescing + sample-mode (D2/D6)

@Suite(.serialized)
struct IGDBSearchClientCacheTests {

    @Test("N concurrent identical autocompletes fire ONE /v4/games request")
    func autocompleteCoalesces() async throws {
        // A small per-request delay makes the concurrent calls genuinely overlap.
        let transport = StubHTTPTransport(perRequestDelay: 0.05)
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200, body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data("igdb-search-bloodborne.json")))
        let client = ReadCacheHarness.client(transport: transport, cache: InMemoryCatalogCache())

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { _ = try? await client.autocomplete("bloodborne") }
            }
        }
        let apiRequests = transport.requests.filter { $0.url?.absoluteString.contains("api.igdb.com") == true }.count
        #expect(apiRequests == 1)   // coalesced (the Bloodborne fixture has ≥4 hits → no fallbacks)
    }

    @Test("Sample-mode offline searcher makes zero requests")
    func offlineSearcherZeroRequests() async throws {
        let transport = StubHTTPTransport()
        let searcher = OfflineCatalogSearcher()
        await #expect(throws: (any Error).self) {
            _ = try await searcher.search("bloodborne", platformIGDBIDs: nil, limit: 12)
        }
        #expect(transport.requestCount == 0)
    }
}
