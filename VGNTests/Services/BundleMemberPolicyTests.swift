import Foundation
import Testing
@testable import VGN

/// The one member policy applied inside ``IGDBClient/bundleMembers(ofBundleID:force:)``
/// (PLAN §5.1, owner 2026-09-20): non-standalone content dropped and reported, a port
/// folded onto its parent through the read-through `games(ids:)` (cache hit ⇒ 0 requests,
/// miss ⇒ one paced lookup), dedupe + release ordering, and the real owner cases as
/// fixtures. Also proves every production producer path goes through the one function.
private final class PolicyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String] = []
    /// reverse-lookup responses keyed by bundle id (`where bundles = (id)`).
    let reverse: [Int64: String]
    /// `/v4/games` id-lookup rows keyed by igdb id (for a port's `games(ids:)` fold).
    let byID: [Int64: String]

    init(reverse: [Int64: String], byID: [Int64: String] = [:]) {
        self.reverse = reverse
        self.byID = byID
    }

    var allBodies: [String] { lock.withLock { bodies } }
    var reverseCount: Int { allBodies.filter { $0.contains("bundles = (") }.count }
    var idLookupCount: Int { allBodies.filter { $0.contains("where id = (") }.count }

    private func idSet(in body: String) -> [Int64] {
        guard let open = body.range(of: "id = (") else { return [] }
        let rest = body[open.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return [] }
        return rest[..<close].split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var data = Data("[]".utf8)
        if url.contains("id.twitch.tv") {
            data = Data(#"{"access_token":"tok","expires_in":3600,"token_type":"bearer"}"#.utf8)
        } else {
            lock.withLock { bodies.append(body) }
            if body.contains("bundles = (") {
                for (id, json) in reverse where body.contains("bundles = (\(id))") { data = Data(json.utf8) }
            } else if body.contains("where id = (") {
                let rows = idSet(in: body).compactMap { byID[$0] }
                data = Data(("[" + rows.joined(separator: ",") + "]").utf8)
            }
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (data, http)
    }
}

struct BundleMemberPolicyTests {
    private func makeClient(reverse: [Int64: String], byID: [Int64: String] = [:]) -> (IGDBClient, PolicyTransport) {
        let transport = PolicyTransport(reverse: reverse, byID: byID)
        let client = IGDBClient(
            transport: transport,
            credentials: { IGDBCredentials(clientID: "cid", secret: "sec") },
            catalog: TestCatalog.catalog,
            cache: InMemoryCatalogCache())
        return (client, transport)
    }

    // MARK: Ports fold onto their parent

    @Test("A port member folds onto its parent — one paced lookup on a miss, zero on a repeat")
    func portFoldViaMissThenCacheHit() async throws {
        let (client, transport) = makeClient(
            reverse: [100: #"[{"id":11,"name":"Super Mario Galaxy","game_type":11,"version_parent":10}]"#],
            byID: [10: #"{"id":10,"name":"Super Mario Galaxy","game_type":0,"first_release_date":1183248000}"#])

        let first = try await client.bundleMembers(ofBundleID: 100)
        #expect(first.members.map(\.id) == [10])                 // the port became its parent
        #expect(transport.idLookupCount == 1)                    // exactly one paced parent lookup
        #expect(first.leftOut.count == 1)
        #expect(first.leftOut.first?.folded == true)
        #expect(first.leftOut.first?.displayText == "Super Mario Galaxy → the 2007 original")

        let second = try await client.bundleMembers(ofBundleID: 100)
        #expect(second.members.map(\.id) == [10])
        #expect(transport.reverseCount == 1)                     // no new reverse lookup
        #expect(transport.idLookupCount == 1)                    // and no new parent lookup — all cached
    }

    @Test("Super Mario 3D All-Stars: three ports resolve to the three originals in one batched lookup")
    func threeDAllStarsResolvesToOriginals() async throws {
        let (client, transport) = makeClient(
            reverse: [200: #"""
            [{"id":31,"name":"Super Mario 64","game_type":11,"version_parent":21},
             {"id":32,"name":"Super Mario Sunshine","game_type":11,"version_parent":22},
             {"id":33,"name":"Super Mario Galaxy","game_type":11,"version_parent":23}]
            """#],
            byID: [
                21: #"{"id":21,"name":"Super Mario 64","game_type":0,"first_release_date":838857600}"#,
                22: #"{"id":22,"name":"Super Mario Sunshine","game_type":0,"first_release_date":1027987200}"#,
                23: #"{"id":23,"name":"Super Mario Galaxy","game_type":0,"first_release_date":1183248000}"#,
            ])
        let result = try await client.bundleMembers(ofBundleID: 200)
        #expect(result.members.map(\.id) == [21, 22, 23])        // originals, release-date ordered
        #expect(result.members.allSatisfy { $0.gameType == .mainGame })
        #expect(transport.idLookupCount == 1)                    // one batched lookup for all three
        #expect(result.leftOut.count == 3 && result.leftOut.allSatisfy(\.folded))
    }

    @Test("An unresolvable parent keeps the port itself")
    func unresolvedParentKeepsPort() async throws {
        let (client, _) = makeClient(
            reverse: [600: #"[{"id":61,"name":"Weird Port","game_type":11,"version_parent":60}]"#],
            byID: [:])   // parent 60 not served
        let result = try await client.bundleMembers(ofBundleID: 600)
        #expect(result.members.map(\.id) == [61])                // the port stays
        #expect(result.leftOut.isEmpty)                          // nothing folded
    }

    @Test("A bundle listing both a port and its original de-duplicates after folding")
    func dedupeAfterFold() async throws {
        let (client, _) = makeClient(
            reverse: [500: #"[{"id":51,"name":"Myst","game_type":0,"first_release_date":749433600},{"id":52,"name":"Myst","game_type":11,"version_parent":51}]"#],
            byID: [51: #"{"id":51,"name":"Myst","game_type":0,"first_release_date":749433600}"#])
        let result = try await client.bundleMembers(ofBundleID: 500)
        #expect(result.members.map(\.id) == [51])                // the port collapsed onto the original
        #expect(result.leftOut.contains { $0.folded })
    }

    // MARK: Non-standalone content dropped + reported

    @Test("Arkham Knight Special Edition: the Season of Infamy expansion is dropped and reported")
    func arkhamKnightExpansionDropped() async throws {
        let (client, transport) = makeClient(
            reverse: [300: #"[{"id":41,"name":"Batman: Arkham Knight","game_type":0},{"id":42,"name":"Season of Infamy","game_type":2}]"#])
        let result = try await client.bundleMembers(ofBundleID: 300)
        #expect(result.members.map(\.name) == ["Batman: Arkham Knight"])
        #expect(result.leftOut.map(\.displayText) == ["Season of Infamy — expansion"])
        #expect(transport.idLookupCount == 0)                    // an expansion needs no parent lookup
    }

    @Test("A Telltale season bundle keeps its episodes (sold and played on their own)")
    func telltaleEpisodesKept() async throws {
        let (client, _) = makeClient(
            reverse: [400: #"""
            [{"id":71,"name":"Episode 1","game_type":6},{"id":72,"name":"Episode 2","game_type":6},
             {"id":73,"name":"Episode 3","game_type":6},{"id":74,"name":"Episode 4","game_type":6},
             {"id":75,"name":"Episode 5","game_type":6}]
            """#])
        let result = try await client.bundleMembers(ofBundleID: 400)
        #expect(result.members.count == 5)
        #expect(result.leftOut.isEmpty)
    }

    // MARK: < 2 members

    @Test("Dropping down to one or zero members is not worth a compilation")
    func fewerThanTwoIsNotACompilation() async throws {
        // One main + one expansion → one kept.
        let (client, _) = makeClient(
            reverse: [301: #"[{"id":81,"name":"Base","game_type":0},{"id":82,"name":"Add-on","game_type":1}]"#])
        let one = try await client.bundleMembers(ofBundleID: 301)
        #expect(one.members.count == 1 && !one.isWorthCompilation)

        // All add-on content → zero kept.
        let (client2, _) = makeClient(
            reverse: [302: #"[{"id":91,"name":"DLC A","game_type":1},{"id":92,"name":"DLC B","game_type":1}]"#])
        let zero = try await client2.bundleMembers(ofBundleID: 302)
        #expect(zero.members.isEmpty && !zero.isWorthCompilation && zero.leftOut.count == 2)
    }

    // MARK: One choke point — every production producer path applies the policy

    @Test("Live catalogue searcher, scan searcher and import expander all drop the DLC via the one function")
    func everyProducerGoesThroughTheOneFunction() async throws {
        let (client, _) = makeClient(
            reverse: [700: #"[{"id":1,"name":"Main","game_type":0},{"id":2,"name":"Some DLC","game_type":1}]"#])

        let catalogSearcher = LiveCatalogSearcher(client: client,
                                                  credentials: { IGDBCredentials(clientID: "c", secret: "s") })
        let scanSearcher = LiveScanSearcher(client: client, catalog: TestCatalog.catalog)
        let expander = IGDBImportBundleExpander(client: client)

        let a = try await catalogSearcher.bundleMembers(bundleIGDBID: 700)
        let b = try await scanSearcher.bundleMembers(bundleIGDBID: 700)
        let c = try await expander.members(ofBundleIGDBID: 700)

        for result in [a, b, c] {
            #expect(result.members.map(\.name) == ["Main"])
            #expect(result.leftOut.map(\.displayText) == ["Some DLC — DLC"])
        }
    }

    // MARK: Import matcher — port best-match folds onto its parent (PLAN §5.1 D4)

    @Test("IGDBImportBundleExpander resolves port matches to their parent in one batched games(ids:)")
    func resolvingPortParentsFoldsToTheOriginal() async throws {
        let (client, transport) = makeClient(
            reverse: [:],
            byID: [10: #"{"id":10,"name":"Super Mario Galaxy","game_type":0,"first_release_date":1183248000}"#])
        let expander = IGDBImportBundleExpander(client: client)

        let port = ScanMatch(igdbID: 20, name: "Super Mario Galaxy", releaseYear: 2020,
                             coverImageID: nil, platformSlugs: ["switch"], score: 0.95,
                             matchedName: "Super Mario Galaxy", gameType: .port, foldParentID: 10)
        let main = ScanMatch(igdbID: 30, name: "Other Game", releaseYear: 2019, coverImageID: nil,
                             platformSlugs: ["pc"], score: 0.9, matchedName: "Other Game", gameType: .mainGame)

        let resolved = await expander.resolvingPortParents([port, main])
        #expect(resolved[0].igdbID == 10)                    // the port became its parent
        #expect(resolved[0].resolvedFromPortID == 20)
        #expect(resolved[0].releaseYear == 2007)
        #expect(resolved[1].igdbID == 30)                    // a non-port is untouched
        #expect(transport.idLookupCount == 1)                // one batched parent lookup
    }

    @Test("A port whose parent does not resolve keeps the port entry")
    func resolvingPortParentsKeepsUnresolvablePort() async throws {
        let (client, _) = makeClient(reverse: [:], byID: [:])   // parent 10 not served
        let expander = IGDBImportBundleExpander(client: client)
        let port = ScanMatch(igdbID: 20, name: "Weird Port", releaseYear: 2020, coverImageID: nil,
                             platformSlugs: ["switch"], score: 0.95, matchedName: "Weird Port",
                             gameType: .port, foldParentID: 10)
        let resolved = await expander.resolvingPortParents([port])
        #expect(resolved[0].igdbID == 20)
        #expect(resolved[0].resolvedFromPortID == nil)
    }
}
