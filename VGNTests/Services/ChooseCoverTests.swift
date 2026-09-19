import Foundation
import CoreGraphics
import Testing
import GRDB
@testable import VGN

// MARK: - libretro: enumerate every region/variant (PLAN §5.2 step 4)

struct LibretroAllCandidatesTests {

    private func provider() throws -> (LibretroCoverProvider, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vgn-libretro-all-\(UUID().uuidString)")
        let transport = StubHTTPTransport()
        transport.on(urlContains: "git/trees",
                     .init(status: 200, body: try Fixtures.data("libretro-tree-dreamcast.json")))
        let listing = LibretroRepoListing(transport: transport, cacheDirectory: tmp)
        return (LibretroCoverProvider(catalog: TestCatalog.catalog, listing: listing), tmp)
    }

    @Test("allCandidates returns one boxart per region, not just the best")
    func everyRegion() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Crazy Taxi has exactly Europe / Japan / USA boxarts in the fixture.
        let all = await provider.allCandidates(for: CoverQuery(title: "Crazy Taxi", platformSlugs: ["dreamcast"]))
        #expect(all.count == 3)
        #expect(all.allSatisfy { $0.providerID == "libretro" })
        #expect(Set(all.compactMap(\.region)) == ["Europe", "Japan", "USA"])
        // Every candidate points at a distinct raw URL.
        #expect(Set(all.map(\.remoteURL)).count == 3)
    }

    @Test("allCandidates offers more than the single automatic match")
    func widerThanSingle() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let query = CoverQuery(title: "Sonic Adventure", platformSlugs: ["dreamcast"])
        let single = await provider.candidates(for: query)
        let all = await provider.allCandidates(for: query)
        #expect(single.count == 1)
        #expect(all.count > single.count)
        // Best-first: the top all-candidate is at least as good as the single match.
        #expect((all.first?.score ?? 0) >= (single.first?.score ?? 0))
    }

    @Test("No repo for the platform yields no candidates")
    func noRepo() async throws {
        let (provider, tmp) = try provider()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let all = await provider.allCandidates(for: CoverQuery(title: "Bloodborne", platformSlugs: ["ps4"]))
        #expect(all.isEmpty)
    }
}

// MARK: - chain: all providers, no short-circuit

struct CoverChainAllCandidatesTests {

    private func candidate(_ provider: String, _ url: String, confident: Bool = true) -> CoverCandidate {
        CoverCandidate(providerID: provider, remoteURL: URL(string: url)!,
                       label: provider, score: 1, isConfident: confident)
    }

    @Test("allCandidates keeps every provider's hits even past a confident one")
    func noShortCircuit() async {
        let chain = CoverProviderChain(providers: [
            StubCoverProvider(id: "libretro") { _ in [self.candidate("libretro", "https://x/l.png")] },
            StubCoverProvider(id: "igdb") { _ in [self.candidate("igdb", "https://x/i.png")] },
        ])
        let all = await chain.allCandidates(CoverQuery(title: "x"))
        #expect(all.map(\.providerID) == ["libretro", "igdb"])
    }

    @Test("allCandidates de-duplicates identical URLs across providers")
    func dedupes() async {
        let shared = "https://x/same.png"
        let chain = CoverProviderChain(providers: [
            StubCoverProvider(id: "a") { _ in [self.candidate("a", shared)] },
            StubCoverProvider(id: "b") { _ in [self.candidate("a", shared)] },
        ])
        let all = await chain.allCandidates(CoverQuery(title: "x"))
        #expect(all.count == 1)
    }
}

// MARK: - CoverStore: list / preview (no disk) / choose

private struct StoreFixture {
    let store: CoverStore
    let transport: StubHTTPTransport
    let root: URL

    init(candidates: @escaping @Sendable (CoverQuery) -> [CoverCandidate]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vgn-choose-\(UUID().uuidString)")
        let transport = StubHTTPTransport()
        transport.setDefault(.init(status: 200, body: TestImage.png(width: 400, height: 533)))
        let chain = CoverProviderChain(providers: [StubCoverProvider(id: "stub", candidates)])
        self.root = root
        self.transport = transport
        self.store = CoverStore(
            chain: chain, transport: transport,
            coversDirectory: root.appendingPathComponent("covers"),
            thumbsDirectory: root.appendingPathComponent("thumbs"))
    }

    func filesInCovers() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("covers").path)) ?? []
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

struct CoverStoreChooseTests {

    private func candidate(_ url: String) -> CoverCandidate {
        CoverCandidate(providerID: "stub", remoteURL: URL(string: url)!,
                       label: "stub", score: 1, isConfident: true)
    }

    @Test("candidates(for:) surfaces every provider hit")
    func listsAll() async {
        let fixture = StoreFixture(candidates: { _ in
            [self.candidate("https://x/a.png"), self.candidate("https://x/b.png")]
        })
        defer { fixture.cleanup() }
        let all = await fixture.store.candidates(for: CoverQuery(title: "x"))
        #expect(all.count == 2)
    }

    @Test("candidatePreview decodes in memory and never writes to covers/")
    func previewStaysInMemory() async {
        let fixture = StoreFixture(candidates: { _ in [] })
        defer { fixture.cleanup() }

        let image = await fixture.store.candidatePreview(
            from: URL(string: "https://x/preview.png")!, maxPixel: 256)
        #expect(image != nil)
        #expect(image!.width <= 256 && image!.height <= 256)   // downsampled
        // Nothing was filed — an unchosen candidate must not pollute the library.
        #expect(fixture.filesInCovers().isEmpty)
        #expect(fixture.transport.requestCount == 1)

        // A second identical preview is served from the in-memory cache.
        _ = await fixture.store.candidatePreview(from: URL(string: "https://x/preview.png")!, maxPixel: 256)
        #expect(fixture.transport.requestCount == 1)
    }

    @Test("chooseRemoteCover downloads and files the chosen image")
    func choosesRemote() async throws {
        let fixture = StoreFixture(candidates: { _ in [] })
        defer { fixture.cleanup() }
        let stored = try await fixture.store.chooseRemoteCover(
            from: URL(string: "https://x/chosen.png")!, gameID: 7)
        #expect(stored.coverFile.hasPrefix("7-"))
        #expect(fixture.filesInCovers().contains(stored.coverFile))
    }
}

// MARK: - ChooseCoverService: query + user-edited write

struct ChooseCoverServiceTests {

    private func makeStore(root: URL, candidates: @escaping @Sendable (CoverQuery) -> [CoverCandidate]) -> CoverStore {
        let transport = StubHTTPTransport()
        transport.setDefault(.init(status: 200, body: TestImage.png(width: 400, height: 533)))
        let chain = CoverProviderChain(providers: [StubCoverProvider(id: "stub", candidates)])
        return CoverStore(
            chain: chain, transport: transport,
            coversDirectory: root.appendingPathComponent("covers"),
            thumbsDirectory: root.appendingPathComponent("thumbs"))
    }

    @Test("Choosing a candidate files the cover and marks it user-edited")
    func chooseMarksUserEdited() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "Crazy Taxi", platformIDs: ["pc"], owned: true)).gameID

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root) { _ in
            [CoverCandidate(providerID: "stub", remoteURL: URL(string: "https://x/c.png")!,
                            label: "stub", score: 1, isConfident: true)]
        }
        let service = ChooseCoverService(coverStore: store, library: lib, allowsNetwork: true)

        let candidates = await service.coverCandidates(forGameID: id)
        let chosen = try #require(candidates.first)
        try await service.chooseCandidate(chosen, forGameID: id)

        let detail = try #require(try await lib.gameDetail(id: id))
        #expect(detail.coverFile != nil)
        #expect(detail.userEditedCover)               // protected from enrichment
    }

    @Test("Choosing a local file also marks the cover user-edited")
    func importFileMarksUserEdited() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "Shenmue", platformIDs: ["pc"], owned: true)).gameID

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let src = root.appendingPathComponent("mine.png")
        try TestImage.png(width: 300, height: 400).write(to: src)

        let service = ChooseCoverService(coverStore: makeStore(root: root) { _ in [] },
                                         library: lib, allowsNetwork: true)
        try await service.importCoverFile(src, forGameID: id)

        let detail = try #require(try await lib.gameDetail(id: id))
        #expect(detail.coverFile != nil)
        #expect(detail.userEditedCover)
    }

    @Test("Outside live mode the service never lists candidates (no network)")
    func offlineListsNothing() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "Sonic Adventure", platformIDs: ["pc"], owned: true)).gameID

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root) { _ in
            [CoverCandidate(providerID: "stub", remoteURL: URL(string: "https://x/c.png")!,
                            label: "stub", score: 1, isConfident: true)]
        }
        let service = ChooseCoverService(coverStore: store, library: lib, allowsNetwork: false)
        #expect(await service.coverCandidates(forGameID: id).isEmpty)
    }
}
