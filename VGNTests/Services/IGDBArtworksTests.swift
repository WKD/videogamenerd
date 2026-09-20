import Foundation
import Testing
@testable import VGN

/// D1: the on-demand IGDB artwork fetch for the "Choose Cover…" sheet (PLAN §5.2 step 4).
/// Drives `IGDBClient.artworks(forGameID:)` end-to-end against a synthetic fixture through a
/// stub transport (token endpoint + `/v4/games`). No network.
struct IGDBArtworksTests {
    private static let credentials: @Sendable () async -> IGDBCredentials? = {
        IGDBCredentials(clientID: "cid", secret: "sec")
    }

    private func client(fixture: String) throws -> (IGDBClient, StubHTTPTransport) {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200,
                           body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data(fixture)))
        let c = IGDBClient(transport: transport, credentials: Self.credentials,
                           catalog: TestCatalog.catalog)
        return (c, transport)
    }

    @Test("Parses artworks with their source dimensions; dimensionless ones still parse")
    func parsesArtworks() async throws {
        let (client, _) = try client(fixture: "igdb-artworks-synthetic.json")
        let arts = try await client.artworks(forGameID: 7346)
        #expect(arts.count == 3)
        #expect(arts[0] == IGDBArtwork(imageID: "artA", width: 1920, height: 1080))
        #expect(arts[1] == IGDBArtwork(imageID: "artB", width: 3840, height: 2160))
        #expect(arts[2] == IGDBArtwork(imageID: "artNoSize", width: nil, height: nil))
    }

    @Test("The request is one games query carrying the artwork fields and the game id")
    func queriesByID() async throws {
        let (client, transport) = try client(fixture: "igdb-artworks-synthetic.json")
        _ = try await client.artworks(forGameID: 7346)
        let body = transport.lastBody ?? ""   // the /v4/games POST is the last request
        #expect(body.contains("artworks.image_id"))
        #expect(body.contains("artworks.width"))
        #expect(body.contains("artworks.height"))
        #expect(body.contains("where id = 7346"))
    }

    @Test("Artwork image URL uses the IGDB image CDN")
    func artworkURL() {
        let url = IGDBImageURL.artwork(imageID: "artA")
        #expect(url?.absoluteString == "https://images.igdb.com/igdb/image/upload/t_1080p/artA.jpg")
    }
}
