import Foundation
import Testing
@testable import VGN

/// §7b IGDB trait + crowd-rating decoding, against the recorded 12-game corpus
/// fixture (`igdb-games-corpus.json`) — the same data the engine tests use.
struct IGDBTraitsTests {

    private static func client(fixture: String) throws -> IGDBClient {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200, body: Data(#"{"access_token":"t","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data(fixture)))
        return IGDBClient(
            transport: transport,
            credentials: { IGDBCredentials(clientID: "c", secret: "s") },
            catalog: TestCatalog.catalog)
    }

    private func corpus() async throws -> [Int64: IGDBGameMetadata] {
        let client = try Self.client(fixture: "igdb-games-corpus.json")
        let games = try await client.games(ids: [7334])   // stub returns the whole fixture
        return Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
    }

    @Test("Decodes developers (developer flag), themes, modes, perspectives, similar")
    func bloodborneTraits() async throws {
        let bb = try #require(try await corpus()[7334])
        #expect(bb.name == "Bloodborne")
        #expect(bb.developers.contains("FromSoftware"))            // developer flag kept
        #expect(!bb.developers.contains("Sony Computer Entertainment"))  // publisher filtered out
        #expect(bb.themes.contains("Horror"))
        #expect(bb.gameModes.contains("Single player"))
        #expect(bb.perspectives.contains("Third person"))
        #expect(bb.similarGameIDs.count == 10)
        #expect(bb.similarGameIDs.contains(7331))                  // Uncharted 4 is in Bloodborne's similar list
        // Bloodborne has no franchise/collection in IGDB — a realistic empty case.
        #expect(bb.franchises.isEmpty)
        #expect(bb.series.isEmpty)
    }

    @Test("Keywords are capped to a sane number")
    func keywordsCapped() async throws {
        let bb = try #require(try await corpus()[7334])
        #expect(bb.keywords.count <= IGDBTraitLimits.keywords)
        #expect(!bb.keywords.isEmpty)
    }

    @Test("Franchise + series populate from franchises/collections arrays")
    func franchiseAndSeries() async throws {
        let all = try await corpus()
        let ffx = try #require(all[418])
        #expect(ffx.franchises.contains("Final Fantasy"))
        #expect(ffx.series.contains("Final Fantasy"))
        let ds3 = try #require(all[11133])
        #expect(ds3.franchises.contains("Dark Souls"))
    }

    @Test("Crowd rating resolves total_rating + count")
    func rating() async throws {
        let bb = try #require(try await corpus()[7334])
        let rating = try #require(bb.igdbRating)
        #expect(rating > 85 && rating < 95)
        #expect(bb.igdbRatingCount == 1879)
    }

    @Test("Rating falls back to aggregated then user rating")
    func ratingFallback() async throws {
        // total absent → aggregated used.
        let aggOnly = try #require(try await meta(["aggregated_rating": 70, "aggregated_rating_count": 5]))
        #expect(aggOnly.igdbRating == 70)
        #expect(aggOnly.igdbRatingCount == 5)
        // aggregated absent too → user rating.
        let userOnly = try #require(try await meta(["rating": 60, "rating_count": 9]))
        #expect(userOnly.igdbRating == 60)
        #expect(userOnly.igdbRatingCount == 9)
    }

    /// Decode one synthetic game object through the client (id 1 + `fields`).
    private func meta(_ extra: [String: Any]) async throws -> IGDBGameMetadata? {
        var obj: [String: Any] = ["id": 1, "name": "X"]
        obj.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: [obj])
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv",
                     .init(status: 200, body: Data(#"{"access_token":"t","expires_in":3600,"token_type":"bearer"}"#.utf8)))
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: data))
        let client = IGDBClient(transport: transport,
                                credentials: { IGDBCredentials(clientID: "c", secret: "s") },
                                catalog: TestCatalog.catalog)
        return try await client.games(ids: [1]).first
    }

    @Test("The metadata's [GameTrait] carries every kind, similar as ids")
    func traitsList() async throws {
        let bb = try #require(try await corpus()[7334])
        let traits = bb.traits
        #expect(traits.contains { $0.kind == .developer && $0.value == "FromSoftware" })
        #expect(traits.contains { $0.kind == .theme && $0.value == "Horror" })
        let similar = traits.filter { $0.kind == .similar }
        #expect(similar.count == 10)
        #expect(similar.allSatisfy { Int64($0.value) != nil })
    }
}
