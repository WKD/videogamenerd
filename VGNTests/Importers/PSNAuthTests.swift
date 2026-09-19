import Foundation
import Testing
@testable import VGN

/// PSN auth (PLAN §13.1 rule 5): NPSSO → code → tokens, single-flight refresh, redaction,
/// the login navigation policy, and NPSSO shape validation. No live request (S0).
@Suite struct PSNAuthTests {

    // MARK: - Navigation policy (main-frame-only rule)

    @Test func navigationPolicyTable() {
        let p = PSNLoginNavigationPolicy(allowedHosts: ["playstation.com", "sony.com"])
        #expect(p.decision(for: URL(string: "https://my.playstation.com/login")!, isMainFrame: true) == .allow)
        #expect(p.decision(for: URL(string: "http://playstation.com/")!, isMainFrame: true) == .allow)
        #expect(p.decision(for: URL(string: "https://evil.example/phish")!, isMainFrame: true) == .block)
        // A sub-frame resource (captcha etc.) always loads.
        #expect(p.decision(for: URL(string: "https://evil.example/phish")!, isMainFrame: false) == .allow)
        // The app's custom-scheme redirect is not an http navigation to block.
        #expect(p.decision(for: URL(string: "com.scee.psxandroid.scecompcall://redirect?code=x")!, isMainFrame: true) == .allow)
    }

    @Test func npssoShapeValidation() {
        #expect(PSNAuth.isPlausibleNPSSO(String(repeating: "a", count: 64)))
        #expect(!PSNAuth.isPlausibleNPSSO("too-short"))
        #expect(!PSNAuth.isPlausibleNPSSO("has spaces in it aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        #expect(!PSNAuth.isPlausibleNPSSO(""))
    }

    @Test func formEncodingIsDeterministicAndSafe() {
        let body = PSNAuth.formURLEncoded(["grant_type": "authorization_code", "code": "a b/c"])
        #expect(body == "code=a%20b%2Fc&grant_type=authorization_code")
    }

    // MARK: - Authorization-code extraction

    @Test func authorizationCodeFromRedirect() {
        let response = HTTPURLResponse(
            url: URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!,
            statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "com.example.test://redirect/?code=v3.FAKECODE123"])!
        #expect(PSNAuth.authorizationCode(from: response, redirectURI: "com.example.test://redirect") == "v3.FAKECODE123")
        let noCode = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 302, httpVersion: nil,
                                     headerFields: ["Location": "com.example.test://redirect/?error=access_denied"])!
        #expect(PSNAuth.authorizationCode(from: noCode, redirectURI: "com.example.test://redirect") == nil)
    }

    // MARK: - Sign-in flow

    private func signInTransport() -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(status: 200, body: Data("{}".utf8)))
        t.on(urlContains: "oauth/authorize", .init(status: 302, body: Data(),
            headers: ["Location": "com.example.test://redirect/?code=v3.FAKECODE123"]))
        t.on(urlContains: "oauth/token", .init(status: 200,
            body: (try? Fixtures.data("psn-token.json")) ?? Data(),
            headers: ["Content-Type": "application/json"]))
        return t
    }

    @Test func completeSignInExchangesNpssoForTokens() async throws {
        let transport = signInTransport()
        let auth = PSNAuth(transport: transport, configuration: fakePSNConfig(),
                           tokenStore: InMemoryPSNTokenStore(), now: { importFixedNow })
        #expect(await auth.hasSession() == false)
        try await auth.completeSignIn(npsso: String(repeating: "n", count: 64))
        #expect(await auth.hasSession() == true)
        let token = try await auth.validAccessToken()
        #expect(token.hasPrefix("SYNTHETIC.ACCESS"))
        // The NPSSO / code never appear in the recorded token literals.
        let literals = await auth.redactionLiterals()
        #expect(literals.allSatisfy { !$0.contains("FAKECODE") })
        #expect(!literals.contains(String(repeating: "n", count: 64)))
    }

    @Test func invalidNpssoRejected() async throws {
        let auth = PSNAuth(transport: signInTransport(), configuration: fakePSNConfig(),
                           tokenStore: InMemoryPSNTokenStore(), now: { importFixedNow })
        await #expect(throws: ImportError.self) {
            try await auth.completeSignIn(npsso: "short")
        }
    }

    // MARK: - Single-flight refresh

    @Test func refreshIsSingleFlight() async throws {
        let transport = StubHTTPTransport(
            defaultStub: .init(status: 200, body: (try? Fixtures.data("psn-token.json")) ?? Data(),
                               headers: ["Content-Type": "application/json"]),
            perRequestDelay: 0.05)
        // Seed an already-expired access token (refresh token still valid).
        let store = InMemoryPSNTokenStore(seed: PSNStoredToken(
            accessToken: "OLD.ACCESS", refreshToken: "OLD-REFRESH-tokentokentokentokentoken",
            expiresAt: importFixedNow.addingTimeInterval(-10),
            refreshExpiresAt: importFixedNow.addingTimeInterval(3600)))
        let auth = PSNAuth(transport: transport, configuration: fakePSNConfig(),
                           tokenStore: store, now: { importFixedNow })
        async let a = auth.validAccessToken()
        async let b = auth.validAccessToken()
        _ = try await (a, b)
        let tokenCalls = transport.requests.filter { ($0.url?.absoluteString ?? "").contains("oauth/token") }.count
        #expect(tokenCalls == 1)   // both callers shared one refresh
    }
}
