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
/// `scope` is the login session's cache scope: the same value = the same signed-in
/// session across app launches (the default); a different value = another sign-in.
func seededPSNAuth(transport: HTTPTransport, now: Date = importFixedNow,
                   scope: String = "test-session") -> PSNAuth {
    let store = InMemoryPSNTokenStore(seed: PSNStoredToken(
        accessToken: "SYNTHETIC.ACCESS.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        refreshToken: "SYNTHETIC-REFRESH-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        expiresAt: now.addingTimeInterval(3600),
        refreshExpiresAt: now.addingTimeInterval(60 * 24 * 3600),
        cacheScope: scope))
    return PSNAuth(transport: transport, configuration: fakePSNConfig(),
                   tokenStore: store, now: { now })
}

/// Wire a ``StubHTTPTransport`` with the coherent PSN fixtures (profile, the single trophy
/// list over two pages incl. PS3/Vita titles, game list, purchases + token). Routing is by
/// URL substring; the `offset=10` route is registered before the generic `trophyTitles` route
/// so paging resolves. No `npServiceName` is sent any more (the endpoint ignores it).
func psnHappyPathTransport() throws -> StubHTTPTransport {
    let transport = StubHTTPTransport(defaultStub: .init(status: 200, body: Data("{}".utf8),
                                                         headers: ["Content-Type": "application/json"]))
    func json(_ name: String) throws -> StubHTTPTransport.Stub {
        .init(status: 200, body: try Fixtures.data(name), headers: ["Content-Type": "application/json"])
    }
    transport.on(urlContains: "oauth/token", try json("psn-token.json"))
    transport.on(urlContains: "me/profile2", try json("psn-profile.json"))
    // Trophy paging: page 2 (offset=10) must win over the generic trophyTitles route.
    transport.on(urlContains: "trophyTitles?limit=800&offset=10", try json("psn-trophy-page2.json"))
    transport.on(urlContains: "trophyTitles", try json("psn-trophy-probe.json"))
    transport.on(urlContains: "gamelist/v2", try json("psn-gamelist.json"))
    transport.on(urlContains: "graphql", try json("psn-purchases.json"))
    return transport
}
