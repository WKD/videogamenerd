import Foundation
import Testing
@testable import VGN

struct TimeToBeatProviderTests {

    @Test("IGDBTimeToBeatProvider adapts IGDB rows and tags the source")
    func adapts() async throws {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv", .init(status: 200, body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data("igdb-ttb.json")))
        let client = IGDBClient(
            transport: transport,
            credentials: { IGDBCredentials(clientID: "cid", secret: "sec") },
            catalog: TestCatalog.catalog
        )

        let provider = IGDBTimeToBeatProvider(client: client)
        #expect(provider.id == "igdb")
        let times = try await provider.times(forGameIDs: [7334])
        #expect(times.count == 6)
        #expect(times.allSatisfy { $0.source == "igdb" })
        #expect(times.contains { $0.completely != nil })
    }

    @Test("Empty id list short-circuits without a network call")
    func empty() async throws {
        let transport = StubHTTPTransport()
        let client = IGDBClient(
            transport: transport,
            credentials: { IGDBCredentials(clientID: "cid", secret: "sec") },
            catalog: TestCatalog.catalog
        )
        let provider = IGDBTimeToBeatProvider(client: client)
        let times = try await provider.times(forGameIDs: [])
        #expect(times.isEmpty)
        #expect(transport.requestCount == 0)
    }
}
