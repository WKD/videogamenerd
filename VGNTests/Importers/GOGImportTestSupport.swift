import Foundation
import GRDB
@testable import VGN

/// Shared helpers for the importer test suite. In-memory DB seeded with `pc` + `mac`
/// (the two platforms a GOG import lands on), a fixed wall clock, and a fake matcher.
enum ImportTestDB {
    static let platforms: [PlatformCatalogEntry] = [
        .init(id: "pc", name: "PC (Windows)", short: "PC",
              manufacturer: "Microsoft", group: "Computer", kind: "computer",
              generation: nil, igdbIDs: [6], libretroRepo: nil, sort: 10),
        .init(id: "mac", name: "Mac", short: "Mac",
              manufacturer: "Apple", group: "Computer", kind: "computer",
              generation: nil, igdbIDs: [14], libretroRepo: nil, sort: 20),
    ]

    static func makeSeeded() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try await db.seedPlatforms(from: platforms)
        return db
    }
}

/// A fixed instant, used as the injected wall clock so cache freshness is deterministic.
let importFixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// A deterministic ``ImportMatcher`` for coordinator tests — returns a scripted outcome
/// per title, or "no match" by default. Never touches IGDB.
final class FakeImportMatcher: ImportMatcher, @unchecked Sendable {
    private let lock = NSLock()
    private var byTitle: [String: ScanMatchOutcome] = [:]
    private var _requests: [ImportMatchRequest] = []

    func on(title: String, _ outcome: ScanMatchOutcome) {
        lock.withLock { byTitle[title] = outcome }
    }

    var requests: [ImportMatchRequest] { lock.withLock { _requests } }

    func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
        lock.withLock {
            _requests.append(request)
            return byTitle[request.title] ?? ScanMatchOutcome(best: nil, alternatives: [], bucket: .none)
        }
    }
}

/// Wire a ``StubHTTPTransport`` with the coherent 3-page GOG library + account + owned +
/// token fixtures. Any unmatched URL returns the token stub's `[]` default.
func gogHappyPathTransport() throws -> StubHTTPTransport {
    let transport = StubHTTPTransport(defaultStub: .init(status: 200, body: Data("{}".utf8),
                                                         headers: ["Content-Type": "application/json"]))
    func json(_ name: String) throws -> StubHTTPTransport.Stub {
        .init(status: 200, body: try Fixtures.data(name), headers: ["Content-Type": "application/json"])
    }
    transport.on(urlContains: "auth.gog.com/token", try json("gog-token.json"))
    transport.on(urlContains: "userData.json", try json("gog-userdata-loggedin.json"))
    transport.on(urlContains: "user/data/games", try json("gog-owned-ids.json"))
    transport.on(urlContains: "page=1", try json("gog-products-page1.json"))
    transport.on(urlContains: "page=2", try json("gog-products-page2.json"))
    transport.on(urlContains: "page=3", try json("gog-products-page3.json"))
    return transport
}

/// A GOGAuth whose token store already holds a valid token, so no auth request is made
/// during a sync. `now` is the fixed wall instant; the token expires an hour later.
func seededGOGAuth(transport: HTTPTransport) -> GOGAuth {
    let store = InMemoryGOGTokenStore(seed: GOGStoredToken(
        accessToken: "synthetic-access-token-aaaaaaaaaaaaaaaaaaaaaaaa",
        refreshToken: "synthetic-refresh-token-bbbbbbbbbbbbbbbbbbbbbbbb",
        expiresAt: importFixedNow.addingTimeInterval(3600)))
    return GOGAuth(transport: transport,
                   configuration: fakeGOGConfig(),
                   tokenStore: store,
                   now: { importFixedNow })
}

/// A clearly fake OAuth configuration — never the real Galaxy values (PLAN §14.5).
func fakeGOGConfig() -> GOGAuthConfiguration {
    GOGAuthConfiguration(clientID: "test-client-id", clientSecret: "test-client-secret")
}
