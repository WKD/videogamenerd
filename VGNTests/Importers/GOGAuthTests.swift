import Foundation
import Testing
@testable import VGN

/// ``GOGAuth`` OAuth flow (PLAN §14.1 route a): redirect parsing, code→token exchange,
/// refresh (single-flight), force-refresh, sign-out. All on fakes — ZERO live requests.
@Suite(.timeLimit(.minutes(1)))
struct GOGAuthTests {

    private func tokenTransport() throws -> StubHTTPTransport {
        StubHTTPTransport(defaultStub: .init(status: 200, body: try Fixtures.data("gog-token.json"),
                                             headers: ["Content-Type": "application/json"]))
    }

    // MARK: - Redirect parser

    @Test func redirectParserRecognisesCodeCancelFailAndNonRedirect() {
        let parser = GOGAuthRedirectParser(redirectURI: "https://embed.gog.com/on_login_success?origin=client")
        #expect(parser.parse(URL(string: "https://embed.gog.com/on_login_success?origin=client&code=abc123")!)
                == .code("abc123"))
        #expect(parser.parse(URL(string: "https://embed.gog.com/on_login_success?error=access_denied")!)
                == .cancelled)
        #expect(parser.parse(URL(string: "https://embed.gog.com/on_login_success?error=server_error&error_description=Boom")!)
                == .failed("Boom"))
        #expect(parser.parse(URL(string: "https://auth.gog.com/auth?client_id=x")!)
                == .notARedirect)
    }

    @Test func authorizationURLHasExpectedParameters() {
        let config = fakeGOGConfig()
        let url = config.authorizationURL.absoluteString
        #expect(url.hasPrefix("https://auth.gog.com/auth?"))
        #expect(url.contains("client_id=test-client-id"))
        #expect(url.contains("response_type=code"))
        #expect(url.contains("layout=client2"))
    }

    // MARK: - Sign-in / token exchange

    @Test func completeSignInStoresTokenAndYieldsAccess() async throws {
        let transport = try tokenTransport()
        let store = InMemoryGOGTokenStore()
        let auth = GOGAuth(transport: transport, configuration: fakeGOGConfig(),
                           tokenStore: store, now: { importFixedNow })
        try await auth.completeSignIn(code: "the-code")
        #expect(transport.requestCount == 1)
        #expect(try store.loadToken()?.accessToken == "synthetic-access-token-aaaaaaaaaaaaaaaaaaaaaaaa")
        let access = try await auth.validAccessToken()
        #expect(access == "synthetic-access-token-aaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(transport.requestCount == 1)   // token still valid → no extra request
    }

    @Test func validAccessTokenRefreshesNearExpiry() async throws {
        let transport = try tokenTransport()
        // Seeded token already (near) expired → a refresh happens on first use.
        let store = InMemoryGOGTokenStore(seed: GOGStoredToken(
            accessToken: "old", refreshToken: "old-refresh", expiresAt: importFixedNow.addingTimeInterval(10)))
        let auth = GOGAuth(transport: transport, configuration: fakeGOGConfig(),
                           tokenStore: store, refreshLeeway: 120, now: { importFixedNow })
        let access = try await auth.validAccessToken()
        #expect(access == "synthetic-access-token-aaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(transport.requestCount == 1)
    }

    @Test func noSessionThrowsNotAuthenticated() async throws {
        let auth = GOGAuth(transport: try tokenTransport(), configuration: fakeGOGConfig(),
                           tokenStore: InMemoryGOGTokenStore(), now: { importFixedNow })
        await #expect(throws: ImportError.self) { try await auth.validAccessToken() }
        #expect(await auth.hasSession() == false)
    }

    @Test func forceRefreshAndSignOut() async throws {
        let transport = try tokenTransport()
        let store = InMemoryGOGTokenStore(seed: GOGStoredToken(
            accessToken: "old", refreshToken: "r", expiresAt: importFixedNow.addingTimeInterval(9999)))
        let auth = GOGAuth(transport: transport, configuration: fakeGOGConfig(),
                           tokenStore: store, now: { importFixedNow })
        let refreshed = try await auth.forceRefresh()
        #expect(refreshed == "synthetic-access-token-aaaaaaaaaaaaaaaaaaaaaaaa")
        try await auth.signOut()
        #expect(await auth.hasSession() == false)
        #expect(try store.loadToken() == nil)
    }

    @Test func concurrentRefreshesAreSingleFlight() async throws {
        let transport = StubHTTPTransport(
            defaultStub: .init(status: 200, body: try Fixtures.data("gog-token.json"),
                               headers: ["Content-Type": "application/json"]),
            perRequestDelay: 0.05)
        let store = InMemoryGOGTokenStore(seed: GOGStoredToken(
            accessToken: "old", refreshToken: "r", expiresAt: importFixedNow.addingTimeInterval(10)))
        let auth = GOGAuth(transport: transport, configuration: fakeGOGConfig(),
                           tokenStore: store, refreshLeeway: 120, now: { importFixedNow })
        async let a = auth.validAccessToken()
        async let b = auth.validAccessToken()
        _ = try await (a, b)
        #expect(transport.requestCount == 1)   // coalesced into one refresh
    }
}
