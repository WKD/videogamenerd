import Foundation
import Testing
@testable import VGN

/// Answers `/v4/games` reverse-bundle lookups from a table keyed by the bundle id in
/// `where bundles = (<id>)` — the live shapes recorded for God of War (2026-09-19):
/// Collection(20068).bundles = [Trilogy 44653]; reverse(20068) = GoW I + II remasters;
/// reverse(44653) = Collection (a bundle) + God of War III.
private final class BundleTableTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    var requestBodies: [String] { lock.withLock { bodies } }
    let table: [Int64: String]

    init(table: [Int64: String]) { self.table = table }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var data = Data("[]".utf8)
        if url.contains("id.twitch.tv") {
            data = Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)
        } else {
            lock.withLock { bodies.append(body) }
            for (id, json) in table where body.contains("bundles = (\(id))") { data = Data(json.utf8) }
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (data, http)
    }
}

struct IGDBBundleMembersTests {
    private static let gow: [Int64: String] = [
        20068: #"[{"id":117882,"name":"God of War II","game_type":9},{"id":117883,"name":"God of War","game_type":9}]"#,
        44653: #"[{"id":20068,"name":"God of War Collection","game_type":3,"bundles":[44653]},{"id":499,"name":"God of War III","game_type":0}]"#,
    ]

    private func client(_ table: [Int64: String]) -> (IGDBClient, BundleTableTransport) {
        let transport = BundleTableTransport(table: table)
        let client = IGDBClient(
            transport: transport,
            credentials: { IGDBCredentials(clientID: "cid", secret: "sec") },
            catalog: TestCatalog.catalog,
            cache: InMemoryCatalogCache()
        )
        return (client, transport)
    }

    private func bundle(_ id: Int64, _ name: String, parents: [Int64]) -> IGDBGameMetadata {
        IGDBGameMetadata(
            id: id, name: name, slug: nil, summary: nil, releaseDate: nil, releaseYear: nil,
            coverImageID: nil, platformIGDBIDs: [], platformSlugs: [], genres: [], alternativeNames: [],
            gameType: .bundle, bundleMemberIDs: parents, parentGameID: nil, versionParentID: nil
        )
    }

    @Test("A bundle's own `bundles` field lists its PARENTS and is never used as the member list")
    func forwardBundlesFieldIsIgnored() async throws {
        let (client, transport) = client(Self.gow)
        // Collection.bundles = [Trilogy]: the old code returned "God of War Trilogy" as the only member.
        let members = try await client.bundleMembers(of: bundle(20068, "God of War Collection", parents: [44653]))
        #expect(members.map(\.name).sorted() == ["God of War", "God of War II"])
        #expect(transport.requestBodies.allSatisfy { !$0.contains("id = (44653)") })
    }

    @Test("Nested bundles are expanded into their games, de-duplicated")
    func nestedBundleExpands() async throws {
        let (client, _) = client(Self.gow)
        let members = try await client.bundleMembers(ofBundleID: 44653)
        #expect(Set(members.map(\.name)) == ["God of War", "God of War II", "God of War III"])
        #expect(members.count == 3)
        #expect(!members.contains { $0.isBundle })
    }

    @Test("A nested bundle IGDB knows nothing about stays as a single member")
    func unknownNestedBundleIsKept() async throws {
        let (client, _) = client([1: #"[{"id":2,"name":"Mystery Collection","game_type":3},{"id":3,"name":"Real Game","game_type":0}]"#])
        let members = try await client.bundleMembers(ofBundleID: 1)
        #expect(members.map(\.name) == ["Mystery Collection", "Real Game"])
    }

    @Test("DLC, packs, updates and mods are not compilation members")
    func addOnContentIsDropped() async throws {
        let table: [Int64: String] = [45181: #"[{"id":1,"name":"Mass Effect","game_type":0},{"id":2,"name":"Mass Effect: Bring Down the Sky","game_type":1},{"id":3,"name":"Mass Effect 2","game_type":0},{"id":4,"name":"Cerberus Network","game_type":13}]"#]
        let (client, _) = client(table)
        let members = try await client.bundleMembers(ofBundleID: 45181)
        #expect(members.map(\.name) == ["Mass Effect", "Mass Effect 2"])
    }

    @Test("Cycles in IGDB's bundle graph terminate")
    func cyclesTerminate() async throws {
        let table: [Int64: String] = [
            10: #"[{"id":11,"name":"B","game_type":3}]"#,
            11: #"[{"id":10,"name":"A","game_type":3},{"id":12,"name":"Game","game_type":0}]"#,
        ]
        let (client, _) = client(table)
        let members = try await client.bundleMembers(ofBundleID: 10)
        #expect(members.map(\.name) == ["Game"])
    }
}
