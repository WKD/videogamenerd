import Foundation
import CoreGraphics
import Testing
@testable import VGN

/// D1: IGDB contributes the game's cover AND its artworks as candidates in the "Choose
/// Cover…" sheet, grouped under one IGDB section, labelled by kind (PLAN §5.2 step 4).

@MainActor
struct ChooseCoverArtworkGroupingTests {

    private struct FakeBackend: ChooseCoverProviding {
        let candidates: [CoverCandidate]
        func coverCandidates(forGameID id: Int64) async -> [CoverCandidate] { candidates }
        func candidateThumbnail(for c: CoverCandidate, maxPixel: Int) async -> sending CGImage? { nil }
        func chooseCandidate(_ c: CoverCandidate, forGameID id: Int64) async throws {}
        func importCoverFile(_ url: URL, forGameID id: Int64) async throws {}
    }

    private func candidate(_ provider: String, _ url: String, kind: String?) -> CoverCandidate {
        CoverCandidate(providerID: provider, remoteURL: URL(string: url)!, label: provider,
                       score: 1, isConfident: kind == "cover", kind: kind)
    }

    @Test("The IGDB cover and its artworks fall in one IGDB group, cover first")
    func groupsArtworksWithCover() async throws {
        let backend = FakeBackend(candidates: [
            candidate("libretro", "https://x/l.png", kind: nil),
            candidate("igdb", "https://x/cover.jpg", kind: "cover"),
            candidate("igdb", "https://x/artA.jpg", kind: "artwork"),
            candidate("igdb", "https://x/artB.jpg", kind: "artwork"),
        ])
        let model = ChooseCoverModel(gameID: 1, title: "Game", currentCoverFile: nil, backend: backend)
        await model.load()

        let igdb = try #require(model.groups.first(where: { $0.providerID == "igdb" }))
        #expect(igdb.candidates.count == 3)
        #expect(igdb.candidates.first?.kind == "cover")           // cover first
        #expect(igdb.candidates.dropFirst().allSatisfy { $0.kind == "artwork" } == true)
        // libretro stays its own group.
        #expect(model.groups.contains { $0.providerID == "libretro" })
    }
}

/// The service merges the IGDB artwork fetch into the chain's candidates (live only).
struct ChooseCoverServiceArtworkTests {
    private static let credentials: @Sendable () async -> IGDBCredentials? = {
        IGDBCredentials(clientID: "cid", secret: "sec")
    }

    private func makeIGDBClient() throws -> IGDBClient {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200,
                           body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com",
                     .init(status: 200, body: try Fixtures.data("igdb-artworks-synthetic.json")))
        return IGDBClient(transport: transport, credentials: Self.credentials, catalog: TestCatalog.catalog)
    }

    @Test("coverCandidates merges IGDB artworks with the chain's cover")
    func mergesArtworks() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "Bloodborne", igdbID: 7346,
                                                 platformIDs: ["pc"], owned: true)).gameID

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = StubHTTPTransport()
        transport.setDefault(.init(status: 200, body: TestImage.png(width: 400, height: 533)))
        let chain = CoverProviderChain(providers: [StubCoverProvider(id: "igdb") { _ in
            [CoverCandidate(providerID: "igdb", remoteURL: URL(string: "https://x/cover.jpg")!,
                            label: "IGDB cover", score: 1, isConfident: true, kind: "cover")]
        }])
        let store = CoverStore(chain: chain, transport: transport,
                               coversDirectory: root.appendingPathComponent("covers"),
                               thumbsDirectory: root.appendingPathComponent("thumbs"))
        let service = ChooseCoverService(coverStore: store, library: lib, allowsNetwork: true,
                                         igdbClient: try makeIGDBClient())

        let candidates = await service.coverCandidates(forGameID: id)
        let igdb = candidates.filter { $0.providerID == "igdb" }
        #expect(igdb.contains { $0.kind == "cover" })
        #expect(igdb.filter { $0.kind == "artwork" }.count == 3)   // artA, artB, artNoSize
        // An artwork carries its source dimensions for the tile label.
        let artA = try #require(igdb.first { $0.remoteURL.absoluteString.contains("artA") })
        #expect(artA.pixelSize == CGSize(width: 1920, height: 1080))
    }

    @Test("Sample mode (no client / no network) offers no artworks")
    func offlineNoArtworks() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "X", igdbID: 7346, platformIDs: ["pc"], owned: true)).gameID
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vgn-art-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CoverStore(chain: CoverProviderChain(providers: []),
                               coversDirectory: root.appendingPathComponent("covers"),
                               thumbsDirectory: root.appendingPathComponent("thumbs"))
        let service = ChooseCoverService(coverStore: store, library: lib, allowsNetwork: false)
        #expect(await service.coverCandidates(forGameID: id).isEmpty)
    }
}
