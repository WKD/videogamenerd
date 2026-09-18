import Foundation
import Testing
@testable import VGN

/// Drives `IGDBClient` end-to-end against recorded fixtures through a stub transport
/// (token endpoint + one IGDB endpoint). Exercises decoding *and* DTO→public mapping
/// (platform slugs, release year, game_type).
private enum IGDBHarness {
    static let credentials: @Sendable () async -> IGDBCredentials? = {
        IGDBCredentials(clientID: "cid", secret: "sec")
    }

    static func tokenStub() -> StubHTTPTransport.Stub {
        .init(status: 200, body: Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8))
    }

    static func client(
        fixture: String,
        cache: CatalogCaching = InMemoryCatalogCache()
    ) throws -> (IGDBClient, StubHTTPTransport) {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv", tokenStub())
        transport.on(urlContains: "api.igdb.com", .init(status: 200, body: try Fixtures.data(fixture)))
        let client = IGDBClient(
            transport: transport,
            credentials: credentials,
            catalog: TestCatalog.catalog,
            cache: cache
        )
        return (client, transport)
    }
}

struct IGDBSearchDecodingTests {

    @Test("Decodes and maps the Bloodborne search fixture")
    func bloodborne() async throws {
        let (client, _) = try IGDBHarness.client(fixture: "igdb-search-bloodborne.json")
        let results = try await client.searchGames("bloodborne")
        let bb = try #require(results.first(where: { $0.name == "Bloodborne" }))
        #expect(bb.id == 7334)
        #expect(bb.releaseYear == 2015)
        #expect(bb.coverImageID == "cob99l")
        #expect(bb.platformIGDBIDs == [48])
        #expect(bb.platformSlugs == ["ps4"])
        #expect(bb.genres.contains("Role-playing (RPG)"))
        #expect(bb.alternativeNames.contains("Project Beast"))
        #expect(bb.gameType == .mainGame)
        #expect(bb.isBundle == false)
    }

    @Test("Populates the catalog cache with each returned game")
    func cachePopulated() async throws {
        let cache = InMemoryCatalogCache()
        let (client, _) = try IGDBHarness.client(fixture: "igdb-search-bloodborne.json", cache: cache)
        _ = try await client.searchGames("bloodborne")
        let cached = await cache.entry(forID: 7334)
        #expect(cached != nil)
        #expect((await cache.count) >= 1)
        // Cached blob is the raw game JSON.
        if let json = cached?.json {
            let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
            #expect((obj?["id"] as? NSNumber)?.int64Value == 7334)
        }
    }

    @Test("Decodes French alternative names (Broken Sword / Les Chevaliers de Baphomet)")
    func frenchAltNames() async throws {
        let (client, _) = try IGDBHarness.client(fixture: "igdb-search-broken-sword.json")
        let results = try await client.searchGames("broken sword")
        let all = results.flatMap(\.alternativeNames)
        #expect(all.contains("Les Chevaliers de Baphomet"))
        #expect(results.contains { $0.name.contains("Broken Sword") })
    }

    @Test("Recognises the MGS Legacy Collection as a bundle")
    func bundleType() async throws {
        let (client, _) = try IGDBHarness.client(fixture: "igdb-search-mgs-legacy.json")
        let results = try await client.searchGames("metal gear solid legacy")
        let legacy = try #require(results.first)
        #expect(legacy.name == "Metal Gear Solid: The Legacy Collection")
        #expect(legacy.gameType == .bundle)
        #expect(legacy.isBundle)
    }

    @Test("Passes the platform filter into the query")
    func platformFilter() async throws {
        let (client, transport) = try IGDBHarness.client(fixture: "igdb-search-bloodborne.json")
        _ = try await client.searchGames("bloodborne", platformIGDBIDs: [48], limit: 5)
        let body = try #require(transport.lastBody)
        #expect(body.contains("platforms = (48)"))
        #expect(body.contains(#"search "bloodborne";"#))
        #expect(body.contains("limit 5;"))
    }
}

struct IGDBMetadataDecodingTests {

    @Test("Decodes full metadata (summary + release date) for games(ids:)")
    func fullMetadata() async throws {
        let (client, _) = try IGDBHarness.client(fixture: "igdb-games-bloodborne.json")
        let games = try await client.games(ids: [7334])
        let bb = try #require(games.first)
        #expect(bb.id == 7334)
        #expect(bb.name == "Bloodborne")
        #expect(bb.summary?.isEmpty == false)
        #expect(bb.releaseDate != nil)
        #expect(bb.releaseYear == 2015)
        #expect(bb.platformSlugs == ["ps4"])
    }
}

struct IGDBBundleDecodingTests {

    @Test("Reverse bundle lookup decodes the MGS Legacy members")
    func mgsMembers() async throws {
        let (client, transport) = try IGDBHarness.client(fixture: "igdb-bundle-members-mgs.json")
        let members = try await client.bundleMembers(ofBundleID: 20196)
        #expect(members.count == 9)
        // Uses the reverse relation query.
        #expect(try #require(transport.lastBody).contains("bundles = (20196)"))
    }

    @Test("bundleMembers(of:) falls back to the reverse lookup when `bundles` is empty")
    func fallback() async throws {
        // The recorded live behaviour: bundle games carry an empty `bundles` array, so
        // the provider must fall back to `where bundles = (id)`.
        let (client, transport) = try IGDBHarness.client(fixture: "igdb-bundle-members-ico.json")
        let bundle = IGDBGameMetadata(
            id: 21084, name: "The Ico & Shadow of the Colossus Collection", slug: nil,
            summary: nil, releaseDate: nil, releaseYear: nil, coverImageID: nil,
            platformIGDBIDs: [], platformSlugs: [], genres: [], alternativeNames: [],
            gameType: .bundle, bundleMemberIDs: [], parentGameID: nil, versionParentID: nil
        )
        let members = try await client.bundleMembers(of: bundle)
        #expect(members.count == 2)
        #expect(try #require(transport.lastBody).contains("bundles = (21084)"))
    }
}

struct IGDBTimeToBeatDecodingTests {

    @Test("Decodes the time-to-beat fixture (durations in seconds, some absent)")
    func decode() async throws {
        let (client, _) = try IGDBHarness.client(fixture: "igdb-ttb.json")
        let rows = try await client.timeToBeat(gameIDs: [7334, 45178])
        #expect(rows.count == 6)
        #expect(rows.contains { $0.completely != nil })
        // Every row has a game id and durations are non-negative when present.
        for row in rows {
            #expect(row.gameID > 0)
            if let n = row.normally { #expect(n >= 0) }
        }
    }
}
