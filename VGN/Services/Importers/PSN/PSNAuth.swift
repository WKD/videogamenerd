import Foundation

/// PSN's OAuth token actor (PLAN §13.1 rule 5). Turns an **NPSSO** into an authorization
/// code, the code into access + refresh tokens, refreshes the access token before expiry
/// with a **single-flight** guard, persists only the tokens in the Keychain seam, and
/// wipes them on sign-out. Everything is injected — transport, configuration, token store,
/// clock — so the whole flow is tested with fakes and **never** makes a live request in
/// this lane (S0).
///
/// The NPSSO, the authorization `code`, and the tokens are never logged: they pass through
/// ``ImportRedactor`` and are never put in a fixture, the dev cache index, or an error.
actor PSNAuth {
    private let transport: HTTPTransport
    private let configuration: PSNAuthConfiguration
    private let tokenStore: any PSNTokenStoring
    private let allowList: ImportAllowList
    /// Refresh this many seconds before real expiry.
    private let refreshLeeway: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: PSNStoredToken?
    private var refreshTask: Task<PSNStoredToken, Error>?

    /// Transport for the `authorize` step only. It MUST NOT follow redirects: Sony answers
    /// with `302 Location: com.scee.psxandroid.scecompcall://redirect/?code=…`, and a
    /// redirect-following session dies with "unsupported URL" instead of handing back the
    /// 302 (first live sign-in, 2026-09-19). nil = use `transport` (tests' stubs return the
    /// 302 directly).
    private let authorizeTransport: HTTPTransport?

    init(transport: HTTPTransport,
         authorizeTransport: HTTPTransport? = nil,
         configuration: PSNAuthConfiguration,
         tokenStore: any PSNTokenStoring,
         allowList: ImportAllowList = .psn,
         refreshLeeway: TimeInterval = 120,
         now: @Sendable @escaping () -> Date = { Date() }) {
        self.transport = transport
        self.authorizeTransport = authorizeTransport
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.allowList = allowList
        self.refreshLeeway = refreshLeeway
        self.now = now
    }

    // MARK: - UI-facing sign-in surface (for the WKWebView bridge lane)

    /// The Sony sign-in page the login WebView loads first (route 1, PLAN §13.1).
    nonisolated var loginURL: URL { configuration.loginURL }
    /// The cookie the bridge reads after login (route 1).
    nonisolated var npssoCookieName: String { configuration.npssoCookieName }
    nonisolated var npssoCookieDomain: String { configuration.npssoCookieDomain }
    /// Hosts the login WebView may navigate to on the main frame (PLAN §13.1).
    nonisolated var allowedNavigationHosts: [String] { configuration.allowedNavigationHosts }
    /// The pure navigation policy for the login WebView (PLAN §13.1).
    nonisolated var navigationPolicy: PSNLoginNavigationPolicy {
        PSNLoginNavigationPolicy(allowedHosts: configuration.allowedNavigationHosts)
    }
    /// Shape-only validation of a pasted NPSSO (route 2). The value is never logged.
    nonisolated static func isPlausibleNPSSO(_ raw: String) -> Bool {
        PSNAuthConfiguration.isPlausibleNPSSO(raw)
    }

    // MARK: - Session state

    /// Is there a stored refresh token (a session to use)?
    func hasSession() -> Bool {
        (cached ?? (try? tokenStore.loadToken())) != nil
    }

    /// Complete sign-in from an NPSSO (route 1's cookie value or route 2's pasted string):
    /// NPSSO → authorization code → access + refresh tokens, persisted (PLAN §13.1 rule 5).
    /// Throws ``ImportError/notAuthenticated`` if the NPSSO is invalid.
    func completeSignIn(npsso: String) async throws {
        guard Self.isPlausibleNPSSO(npsso) else { throw ImportError.notAuthenticated }
        let code = try await exchangeNpssoForCode(npsso)
        let token = try await exchange(grant: .authorizationCode(code))
        try persist(token)
    }

    /// A currently-valid access token, refreshing (single-flight) if near expiry.
    /// Throws ``ImportError/notAuthenticated`` when there is no usable session.
    func validAccessToken() async throws -> String {
        let stored = cached ?? (try? tokenStore.loadToken())
        cached = stored
        if let stored, stored.expiresAt.timeIntervalSince(now()) > refreshLeeway {
            return stored.accessToken
        }
        guard let stored, stored.refreshExpiresAt.timeIntervalSince(now()) > 0 else {
            throw ImportError.notAuthenticated   // no session, or the refresh token is dead
        }
        return try await refresh(stored.refreshToken).accessToken
    }

    /// Force a token refresh regardless of expiry — the 401 path (PLAN §13.1 rule 4).
    /// Single-flight. Throws ``ImportError/notAuthenticated`` when there is no session.
    @discardableResult
    func forceRefresh() async throws -> String {
        let stored = cached ?? (try? tokenStore.loadToken())
        guard let refreshToken = stored?.refreshToken else {
            throw ImportError.notAuthenticated
        }
        cached = nil
        return try await refresh(refreshToken).accessToken
    }

    /// Sign out: forget and delete the tokens (PLAN §13.1 rule 5).
    func signOut() throws {
        cached = nil
        try tokenStore.deleteToken()
    }

    /// When the current session's **refresh token** expires — the "sign in again after…"
    /// deadline the Settings pane shows (PLAN §13.1), or nil when there is no session.
    /// UI-only; the tokens themselves never leave this actor. (Additive, wave 11 UI lane.)
    func sessionExpiry() -> Date? {
        (cached ?? (try? tokenStore.loadToken()))?.refreshExpiresAt
    }

    /// Literal token strings to scrub from any persisted/logged text (PLAN §13.2).
    func redactionLiterals() -> [String] {
        guard let token = cached ?? (try? tokenStore.loadToken()) else { return [] }
        return [token.accessToken, token.refreshToken]
    }

    // MARK: - NPSSO → authorization code

    /// GET `…/authorize` with `Cookie: npsso=…`; Sony answers with a redirect whose
    /// `Location` (or resolved URL) carries `?code=…` (PLAN §13.3, ported from psn-api
    /// `exchangeNpssoForAccessCode`). A missing/absent code ⇒ the NPSSO is invalid.
    private func exchangeNpssoForCode(_ npsso: String) async throws -> String {
        let url = configuration.authorizationURL
        try allowList.check(url)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")
        // A non-redirect-following session, so the 302 is observed (see `authorizeTransport`).
        let (_, response) = try await (authorizeTransport ?? transport).data(for: request)
        guard let code = Self.authorizationCode(from: response, redirectURI: configuration.redirectURI) else {
            throw ImportError.notAuthenticated
        }
        return code
    }

    /// Pull the `code` from a redirect response's `Location` header or resolved URL.
    static func authorizationCode(from response: HTTPURLResponse, redirectURI: String) -> String? {
        let candidates = [response.value(forHTTPHeaderField: "Location"),
                          response.value(forHTTPHeaderField: "location"),
                          response.url?.absoluteString].compactMap { $0 }
        for candidate in candidates {
            if let code = code(inRedirect: candidate) { return code }
        }
        return nil
    }

    private static func code(inRedirect raw: String) -> String? {
        // `com.scee.psxandroid.scecompcall://redirect/?code=v3.XXXX` — a custom scheme
        // URLComponents parses fine for the query. Also handle a normal https redirect.
        guard let components = URLComponents(string: raw) else { return nil }
        if let code = components.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return code
        }
        return nil
    }

    // MARK: - Token exchange / refresh

    private enum Grant {
        case authorizationCode(String)
        case refreshToken(String)
    }

    private func refresh(_ refreshToken: String) async throws -> PSNStoredToken {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<PSNStoredToken, Error> { [self] in
            let token = try await exchange(grant: .refreshToken(refreshToken))
            try persist(token)
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func exchange(grant: Grant) async throws -> PSNStoredToken {
        var fields: [String: String] = ["token_format": "jwt"]
        switch grant {
        case .authorizationCode(let code):
            fields["grant_type"] = "authorization_code"
            fields["code"] = code
            fields["redirect_uri"] = configuration.redirectURI
        case .refreshToken(let token):
            fields["grant_type"] = "refresh_token"
            fields["refresh_token"] = token
            fields["scope"] = configuration.scope
        }
        try allowList.check(configuration.tokenEndpoint)
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(configuration.tokenBasicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncoded(fields).data(using: .utf8)

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200,
              let dto = try? JSONDecoder().decode(PSNTokenDTO.self, from: data) else {
            throw ImportError.notAuthenticated
        }
        let issued = now()
        return PSNStoredToken(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresAt: issued.addingTimeInterval(TimeInterval(dto.expiresIn)),
            refreshExpiresAt: issued.addingTimeInterval(TimeInterval(dto.refreshTokenExpiresIn ?? 60 * 24 * 60 * 60)))
    }

    private func persist(_ token: PSNStoredToken) throws {
        cached = token
        try tokenStore.saveToken(token)
    }

    /// `application/x-www-form-urlencoded` body with query-safe percent-encoding, keys
    /// sorted for deterministic output (tests assert on the body).
    static func formURLEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = (fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
}
