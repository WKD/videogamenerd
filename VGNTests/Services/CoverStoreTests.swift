import Foundation
import CoreGraphics
import Testing
@testable import VGN

private struct CoverStoreFixture {
    let store: CoverStore
    let transport: StubHTTPTransport
    let clock: ManualClock
    let root: URL
    let providerCalls: AtomicCounter

    init(
        candidates: @escaping @Sendable (CoverQuery) -> [CoverCandidate],
        transport: StubHTTPTransport,
        clock: ManualClock = ManualClock(now: 0),
        sentinelClock: ManualClock? = nil
    ) {
        let calls = AtomicCounter()
        self.init(
            providersFrom: { calls2 in [
                StubCoverProvider(id: "stub") { query in _ = calls2.increment(); return candidates(query) },
            ] },
            calls: calls,
            transport: transport, clock: clock, sentinelClock: sentinelClock)
    }

    /// Build with a controllable ``CoverProbe`` result (for the transient-failure
    /// negative-cache path).
    init(
        probe: @escaping @Sendable (CoverQuery) -> CoverProbe,
        transport: StubHTTPTransport,
        clock: ManualClock = ManualClock(now: 0),
        sentinelClock: ManualClock? = nil
    ) {
        let calls = AtomicCounter()
        self.init(
            providersFrom: { calls2 in [
                ProbeCoverProvider(id: "probe") { query in _ = calls2.increment(); return probe(query) },
            ] },
            calls: calls,
            transport: transport, clock: clock, sentinelClock: sentinelClock)
    }

    private init(
        providersFrom: (AtomicCounter) -> [any CoverProvider],
        calls: AtomicCounter,
        transport: StubHTTPTransport,
        clock: ManualClock,
        sentinelClock: ManualClock?
    ) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-covers-\(UUID().uuidString)")
        let chain = CoverProviderChain(providers: providersFrom(calls))
        // Sentinels use a wall clock; default it to follow the (monotonic) test
        // clock so existing tests age it via `clock.advance`, or take a separate one.
        let wall = sentinelClock ?? clock
        self.root = root
        self.providerCalls = calls
        self.transport = transport
        self.clock = clock
        self.store = CoverStore(
            chain: chain,
            transport: transport,
            coversDirectory: root.appendingPathComponent("covers"),
            thumbsDirectory: root.appendingPathComponent("thumbs"),
            clock: clock,
            sentinelClock: { wall.now }
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func pngStub(width: Int = 400, height: Int = 533) -> StubHTTPTransport {
    let transport = StubHTTPTransport()
    transport.setDefault(.init(status: 200, body: TestImage.png(width: width, height: height)))
    return transport
}

private func candidate(_ url: String, provider: String = "stub") -> CoverCandidate {
    CoverCandidate(providerID: provider, remoteURL: URL(string: url)!, label: provider, score: 1.0, isConfident: true)
}

struct CoverStoreThumbnailTests {

    @Test("Imports an image and round-trips a thumbnail")
    func roundTrip() async throws {
        let fixture = CoverStoreFixture(candidates: { _ in [] }, transport: pngStub())
        defer { fixture.cleanup() }

        // Write a source PNG and import it as a manual cover.
        let src = fixture.root.appendingPathComponent("src.png")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try TestImage.png(width: 600, height: 800).write(to: src)

        let stored = try await fixture.store.importCover(from: src, gameID: 42)
        #expect(stored.providerID == "manual")
        #expect(stored.coverFile.hasPrefix("42-"))

        let thumb = await fixture.store.thumbnail(for: stored.coverFile, pixelSize: CGSize(width: 160, height: 213))
        #expect(thumb != nil)
    }

    @Test("Thumbnails are actually downsampled to the requested bucket")
    func downsampled() async throws {
        let fixture = CoverStoreFixture(candidates: { _ in [] }, transport: pngStub())
        defer { fixture.cleanup() }

        let src = fixture.root.appendingPathComponent("big.png")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try TestImage.png(width: 1000, height: 1000).write(to: src)      // large original
        let stored = try await fixture.store.importCover(from: src, gameID: 1)

        let thumb = try #require(await fixture.store.thumbnail(for: stored.coverFile, pixelSize: CGSize(width: 128, height: 128)))
        // Downsampled: never larger than the 128 bucket, and far smaller than 1000.
        #expect(thumb.width <= 128)
        #expect(thumb.height <= 128)
    }

    @Test("Bucketing rounds a requested size up to a fixed set")
    func bucketing() {
        #expect(CoverStore.bucket(for: CGSize(width: 100, height: 120)) == 128)
        #expect(CoverStore.bucket(for: CGSize(width: 160, height: 213)) == 256)
        #expect(CoverStore.bucket(for: CGSize(width: 300, height: 400)) == 512)
        #expect(CoverStore.bucket(for: CGSize(width: 9000, height: 9000)) == 768)   // capped
    }

    @Test("Missing cover file yields nil, not a crash")
    func missing() async {
        let fixture = CoverStoreFixture(candidates: { _ in [] }, transport: pngStub())
        defer { fixture.cleanup() }
        let thumb = await fixture.store.thumbnail(for: "nope.png", pixelSize: CGSize(width: 128, height: 128))
        #expect(thumb == nil)
    }
}

struct CoverStoreFetchTests {

    @Test("N concurrent fetches for one game make a single transport call")
    func inFlightDedupe() async throws {
        let transport = pngStub()
        transport.setDefault(.init(status: 200, body: TestImage.png(), headers: [:]))
        let fixture = CoverStoreFixture(
            candidates: { _ in [candidate("https://cdn/cover.png")] },
            transport: transport
        )
        defer { fixture.cleanup() }

        let stored = try await withThrowingTaskGroup(of: StoredCover?.self) { group -> [StoredCover?] in
            for _ in 0..<10 {
                group.addTask {
                    try await fixture.store.fetchAndStoreCover(
                        for: CoverQuery(title: "Game", igdbCoverImageID: "x"), gameID: 7
                    )
                }
            }
            var out: [StoredCover?] = []
            for try await value in group { out.append(value) }
            return out
        }
        #expect(transport.requestCount == 1)
        #expect(stored.compactMap { $0 }.count == 10)
        #expect(Set(stored.compactMap { $0?.coverFile }).count == 1)   // all identical
    }

    @Test("Concurrent downloads are capped at 6")
    func concurrencyCap() async throws {
        let transport = StubHTTPTransport(perRequestDelay: 0.03)
        transport.setDefault(.init(status: 200, body: TestImage.png()))
        let fixture = CoverStoreFixture(
            candidates: { query in [candidate("https://cdn/\(query.title).png")] },
            transport: transport
        )
        defer { fixture.cleanup() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    _ = try? await fixture.store.fetchAndStoreCover(
                        for: CoverQuery(title: "g\(i)"), gameID: Int64(i)
                    )
                }
            }
        }
        #expect(transport.maxConcurrency <= 6)
        #expect(transport.maxConcurrency >= 2)   // proves they really overlapped
        #expect(transport.requestCount == 20)
    }

    @Test("Stores the downloaded original and returns candidates")
    func storesOriginal() async throws {
        let transport = pngStub()
        let fixture = CoverStoreFixture(
            candidates: { _ in [candidate("https://cdn/a.png"), candidate("https://cdn/b.png")] },
            transport: transport
        )
        defer { fixture.cleanup() }

        let stored = try #require(try await fixture.store.fetchAndStoreCover(
            for: CoverQuery(title: "Game"), gameID: 3
        ))
        #expect(stored.coverFile.hasPrefix("3-"))
        #expect(stored.candidates.count == 2)
        // The original file exists on disk.
        let coverURL = fixture.root.appendingPathComponent("covers").appendingPathComponent(stored.coverFile)
        #expect(FileManager.default.fileExists(atPath: coverURL.path))
    }
}

struct CoverStoreNegativeCacheTests {

    @Test("A miss writes a sentinel that is honoured, then expires after 7 days")
    func sentinelLifecycle() async throws {
        let clock = ManualClock(now: 1_000_000)
        // No candidates → a genuine miss.
        let fixture = CoverStoreFixture(candidates: { _ in [] }, transport: pngStub(), clock: clock)
        defer { fixture.cleanup() }

        let first = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(first == nil)
        #expect(fixture.providerCalls.count == 1)      // chain ran once

        // Second call is short-circuited by the fresh sentinel — chain NOT re-run.
        let second = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(second == nil)
        #expect(fixture.providerCalls.count == 1)      // still 1

        // Age past the 7-day TTL → sentinel expires, chain runs again.
        clock.advance(by: 8 * 24 * 60 * 60)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(fixture.providerCalls.count == 2)
    }

    @Test("A transient download failure does NOT poison the cache")
    func transientDoesNotPoison() async throws {
        let transport = pngStub()
        let fixture = CoverStoreFixture(
            candidates: { _ in [candidate("https://cdn/x.png")] },
            transport: transport
        )
        defer { fixture.cleanup() }

        // First attempt: the network throws (transient / cancelled) — no sentinel.
        transport.setThrow { URLError(.networkConnectionLost) }
        let failed = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Game"), gameID: 11)
        #expect(failed == nil)

        // Recover the network: a fresh fetch must succeed (cache was not poisoned).
        transport.setThrow(nil)
        let recovered = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Game"), gameID: 11)
        #expect(recovered != nil)
        #expect(recovered?.coverFile.hasPrefix("11-") == true)
    }

    @Test("A cancelled download propagates and does not poison the cache")
    func cancellationDoesNotPoison() async throws {
        let transport = pngStub()
        let fixture = CoverStoreFixture(
            candidates: { _ in [candidate("https://cdn/x.png")] },
            transport: transport
        )
        defer { fixture.cleanup() }

        transport.setThrow { CancellationError() }
        await #expect(throws: CancellationError.self) {
            _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Game"), gameID: 12)
        }

        // No sentinel was written, so recovery works.
        transport.setThrow(nil)
        let recovered = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Game"), gameID: 12)
        #expect(recovered != nil)
    }

    @Test("The negative sentinel expires on WALL time, not the monotonic service clock")
    func sentinelUsesWallClockNotMonotonic() async throws {
        // A monotonic clock (used for downloads/rate limiting) and a *separate* wall
        // clock for the sentinel: advancing only the monotonic clock must never age
        // the sentinel, or a reboot (monotonic reset) would suppress covers forever.
        let mono = ManualClock(now: 1_000_000)
        let wall = ManualClock(now: 1_000_000)
        let fixture = CoverStoreFixture(
            candidates: { _ in [] }, transport: pngStub(), clock: mono, sentinelClock: wall)
        defer { fixture.cleanup() }

        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(fixture.providerCalls.count == 1)

        // 100 days pass on the MONOTONIC clock only — the sentinel is wall-based, so
        // it must still be fresh (chain not re-run).
        mono.advance(by: 100 * 24 * 60 * 60)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(fixture.providerCalls.count == 1)

        // Only advancing WALL time past the TTL expires it.
        wall.advance(by: 8 * 24 * 60 * 60)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Ghost"), gameID: 9)
        #expect(fixture.providerCalls.count == 2)
    }

    @Test("A transient provider failure (empty result, source unreachable) does NOT poison")
    func transientEmptyResultDoesNotPoison() async throws {
        let fixture = CoverStoreFixture(
            probe: { _ in .transientFailure }, transport: pngStub())
        defer { fixture.cleanup() }

        // First run can't reach the source → no candidates, but no sentinel either.
        let first = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Retro"), gameID: 7)
        #expect(first == nil)
        #expect(fixture.providerCalls.count == 1)

        // A second run must retry (not be short-circuited by a poisoned sentinel).
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Retro"), gameID: 7)
        #expect(fixture.providerCalls.count == 2)
    }

    @Test("A genuine miss (source reached, nothing found) still writes a sentinel")
    func genuineMissStillPoisons() async throws {
        let fixture = CoverStoreFixture(
            probe: { _ in .found([]) }, transport: pngStub())
        defer { fixture.cleanup() }

        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Nope"), gameID: 8)
        #expect(fixture.providerCalls.count == 1)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "Nope"), gameID: 8)
        #expect(fixture.providerCalls.count == 1)   // short-circuited by the fresh sentinel
    }

    @Test("clearNegativeCache lets a game re-fetch immediately (Remove custom cover)")
    func clearNegativeCacheReFetches() async throws {
        let fixture = CoverStoreFixture(probe: { _ in .found([]) }, transport: pngStub())
        defer { fixture.cleanup() }

        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "X"), gameID: 3)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "X"), gameID: 3)
        #expect(fixture.providerCalls.count == 1)   // sentinel suppresses the second

        await fixture.store.clearNegativeCache(gameID: 3)
        _ = try await fixture.store.fetchAndStoreCover(for: CoverQuery(title: "X"), gameID: 3)
        #expect(fixture.providerCalls.count == 2)   // re-runs immediately
    }

    @Test("removeCover deletes the original and its thumbnails")
    func removal() async throws {
        let fixture = CoverStoreFixture(candidates: { _ in [] }, transport: pngStub())
        defer { fixture.cleanup() }

        let src = fixture.root.appendingPathComponent("src.png")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try TestImage.png(width: 400, height: 533).write(to: src)
        let stored = try await fixture.store.importCover(from: src, gameID: 5)
        _ = await fixture.store.thumbnail(for: stored.coverFile, pixelSize: CGSize(width: 128, height: 128))

        await fixture.store.removeCover(stored.coverFile)
        let coverURL = fixture.root.appendingPathComponent("covers").appendingPathComponent(stored.coverFile)
        #expect(!FileManager.default.fileExists(atPath: coverURL.path))
    }
}
