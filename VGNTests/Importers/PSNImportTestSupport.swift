import Foundation
@testable import VGN

/// A clearly **fake** PSN configuration (PLAN §13.5 — tests never use the real mobile-app
/// values). The endpoint hosts are the real ones because the client's allow-list requires
/// them, but the client id, basic-auth, redirect and scope are all synthetic.
func fakePSNConfig() -> PSNAuthConfiguration {
    PSNAuthConfiguration(
        authorizationEndpoint: URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!,
        clientID: "test-client-id",
        tokenBasicAuth: "Basic dGVzdC1jbGllbnQtaWQ6dGVzdC1zZWNyZXQ=",
        redirectURI: "com.example.test://redirect",
        scope: "psn:mobile.v2.core psn:clientapp",
        loginURL: URL(string: "https://my.playstation.com/")!,
        npssoCookieDomain: "ca.account.sony.com",
        ssoCookieEndpoint: URL(string: "https://ca.account.sony.com/api/v1/ssocookie")!,
        allowedNavigationHosts: ["playstation.com", "sony.com", "ca.account.sony.com"])
}

/// A `PSNAuth` whose token store already holds a valid token, so no auth request is made
/// during a sync. `now` is the fixed wall instant; the token expires an hour later, the
/// refresh token two months later.
func seededPSNAuth(transport: HTTPTransport, now: Date = importFixedNow) -> PSNAuth {
    let store = InMemoryPSNTokenStore(seed: PSNStoredToken(
        accessToken: "SYNTHETIC.ACCESS.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        refreshToken: "SYNTHETIC-REFRESH-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        expiresAt: now.addingTimeInterval(3600),
        refreshExpiresAt: now.addingTimeInterval(60 * 24 * 3600)))
    return PSNAuth(transport: transport, configuration: fakePSNConfig(),
                   tokenStore: store, now: { now })
}

/// Wire a ``StubHTTPTransport`` with the coherent PSN fixtures (profile, trophy2 two pages,
/// PS3/Vita trophies, game list, purchases + token). Routing is by URL substring; the
/// `offset=10` route is registered before the generic `trophy2` route so paging resolves.
func psnHappyPathTransport() throws -> StubHTTPTransport {
    let transport = StubHTTPTransport(defaultStub: .init(status: 200, body: Data("{}".utf8),
                                                         headers: ["Content-Type": "application/json"]))
    func json(_ name: String) throws -> StubHTTPTransport.Stub {
        .init(status: 200, body: try Fixtures.data(name), headers: ["Content-Type": "application/json"])
    }
    transport.on(urlContains: "oauth/token", try json("psn-token.json"))
    transport.on(urlContains: "me/profiles", try json("psn-profile.json"))
    // Trophy paging: offset=10 (page 2) must win over the generic trophy2 route.
    transport.on(urlContains: "npServiceName=trophy2&limit=800&offset=10", try json("psn-trophy-page2.json"))
    transport.on(urlContains: "npServiceName=trophy2", try json("psn-trophy-probe.json"))
    transport.on(urlContains: "npServiceName=trophy", try json("psn-trophy-ps3vita.json"))
    transport.on(urlContains: "gamelist/v2", try json("psn-gamelist.json"))
    transport.on(urlContains: "graphql", try json("psn-purchases.json"))
    return transport
}
