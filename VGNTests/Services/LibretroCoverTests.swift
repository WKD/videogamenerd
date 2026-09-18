import Foundation
import Testing
@testable import VGN

struct LibretroTreeParserTests {

    @Test("Parses Named_Boxarts PNGs and ignores other folders")
    func parse() throws {
        let data = try Fixtures.data("libretro-tree-dreamcast.json")
        let parsed = try LibretroTreeParser.parse(data)
        #expect(parsed.truncated == false)
        #expect(parsed.filenames.count > 20)
        // Every entry is a bare boxart PNG name (no directory prefix).
        #expect(parsed.filenames.allSatisfy { !$0.contains("/") && $0.hasSuffix(".png") })
        #expect(parsed.filenames.contains { $0.hasPrefix("Sonic Adventure (") })
        #expect(parsed.filenames.contains { $0.hasPrefix("Shenmue (") })
        // Named_Snaps blobs must not leak in.
        #expect(!parsed.filenames.contains { $0.contains("Snap") })
        // The Named_Boxarts folder tree sha is available for the truncation path.
        #expect(parsed.boxartsSHA != nil)
    }
}

struct LibretroRepoListingTests {

    private func listing(clock: ServiceClock = SystemClock()) throws -> (LibretroRepoListing, StubHTTPTransport, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vgn-libretro-\(UUID().uuidString)")
        let transport = StubHTTPTransport()
        transport.on(urlContains: "git/trees", .init(status: 200, body: try Fixtures.data("libretro-tree-dreamcast.json")))
        let listing = LibretroRepoListing(
            transport: transport,
            cacheDirectory: tmp,
            rateLimiter: RateLimiter(rate: 100, clock: clock),
            clock: clock
        )
        return (listing, transport, tmp)
    }

    @Test("Fetches, parses, and disk-caches a repo listing")
    func fetchAndCache() async throws {
        let (repo, transport, tmp) = try listing()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let first = try #require(await repo.listing(repo: "Sega_-_Dreamcast"))
        #expect(first.branch == "master")
        #expect(first.filenames.count > 20)
        #expect(transport.requestCount == 1)

        // Second call is served from memory — no extra request.
        _ = await repo.filenames(repo: "Sega_-_Dreamcast")
        #expect(transport.requestCount == 1)

        // A disk cache file was written.
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("Sega_-_Dreamcast.json").path))
    }

    @Test("Failures are negative-cached briefly (no repeated hammering)")
    func negativeCache() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-libretro-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let clock = ManualClock(now: 0)
        // 404 on every branch → not found.
        let transport = StubHTTPTransport(defaultStub: .init(status: 404, body: Data()))
        let repo = LibretroRepoListing(
            transport: transport,
            cacheDirectory: tmp,
            rateLimiter: RateLimiter(rate: 100, clock: clock),
            clock: clock
        )
        #expect(await repo.filenames(repo: "Missing_Repo") == nil)
        let after404 = transport.requestCount   // tried master + main
        #expect(after404 >= 1)

        // A prompt retry does not hit the network again (negative cache honoured).
        #expect(await repo.filenames(repo: "Missing_Repo") == nil)
        #expect(transport.requestCount == after404)
    }
}

struct LibretroCoverProviderTests {

    private func provider() throws -> (LibretroCoverProvider, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-libretro-\(UUID().uuidString)")
        let transport = StubHTTPTransport()
        transport.on(urlContains: "git/trees", .init(status: 200, body: try Fixtures.data("libretro-tree-dreamcast.json")))
        let listing = LibretroRepoListing(transport: transport, cacheDirectory: tmp)
        return (LibretroCoverProvider(catalog: TestCatalog.catalog, listing: listing), tmp)
    }

    @Test("Matches a title to the preferred-region boxart and builds a raw URL")
    func match() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let query = CoverQuery(title: "Sonic Adventure", platformSlugs: ["dreamcast"])
        let candidates = await provider.candidates(for: query)

        let best = try #require(candidates.first)
        #expect(best.providerID == "libretro")
        #expect(best.isConfident)                       // exact title → ≥ confident
        #expect(best.label.contains("Europe"))          // Europe preferred by default
        let url = best.remoteURL.absoluteString
        #expect(url.contains("raw.githubusercontent.com/libretro-thumbnails/Sega_-_Dreamcast/master/Named_Boxarts/"))
        #expect(url.contains("Sonic%20Adventure"))       // spaces percent-encoded
    }

    @Test("Region preference is honoured")
    func regionPreference() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let query = CoverQuery(
            title: "Shenmue",
            platformSlugs: ["dreamcast"],
            preferredRegions: ["USA", "Europe", "Japan"]
        )
        let best = try #require(await provider.candidates(for: query).first)
        #expect(best.label.contains("USA"))
    }

    @Test("No repo for the platform yields no candidates")
    func noRepo() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // ps4 has no libretro repo.
        let candidates = await provider.candidates(for: CoverQuery(title: "Bloodborne", platformSlugs: ["ps4"]))
        #expect(candidates.isEmpty)
    }
}

struct CoverProviderChainTests {

    private func candidate(_ provider: String, score: Double, confident: Bool) -> CoverCandidate {
        CoverCandidate(
            providerID: provider,
            remoteURL: URL(string: "https://example.com/\(provider).png")!,
            label: provider, score: score, isConfident: confident
        )
    }

    @Test("First confident hit wins and short-circuits later providers")
    func shortCircuit() async throws {
        let igdbCalls = AtomicCounter()
        let chain = CoverProviderChain(providers: [
            StubCoverProvider(id: "libretro") { _ in [self.candidate("libretro", score: 1.0, confident: true)] },
            StubCoverProvider(id: "igdb") { _ in _ = igdbCalls.increment(); return [self.candidate("igdb", score: 1.0, confident: true)] },
        ])
        let result = await chain.run(CoverQuery(title: "x"))
        #expect(result.bestConfident?.providerID == "libretro")
        #expect(igdbCalls.count == 0)                 // never reached
        #expect(result.allCandidates.count == 1)
    }

    @Test("Plausible-only libretro falls through to the IGDB fallback, keeping both")
    func fallThrough() async throws {
        let chain = CoverProviderChain(providers: [
            StubCoverProvider(id: "libretro") { _ in [self.candidate("libretro", score: 0.8, confident: false)] },
            StubCoverProvider(id: "igdb") { _ in [self.candidate("igdb", score: 1.0, confident: true)] },
        ])
        let result = await chain.run(CoverQuery(title: "x"))
        #expect(result.bestConfident?.providerID == "igdb")
        #expect(result.allCandidates.map(\.providerID) == ["libretro", "igdb"])  // both browsable
    }
}
