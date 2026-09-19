import Foundation

/// GOG's OAuth token actor (PLAN §14.1 route a). Turns the authorization `code` into
/// an access + refresh token, refreshes the access token before it expires with a
/// **single-flight** guard, persists only the tokens in the Keychain seam, and wipes
/// them on sign-out. Everything is injected — transport, configuration, token store,
/// clock — so the whole flow is tested with fakes and **never** makes a live request
/// in this lane (G0).
///
/// The `code`, tokens, `user_id` and `session_id` are never logged: the exchange
/// response is scrubbed through ``ImportRedactor`` and the ids are discarded.
actor GOGAuth {
    private let transport: HTTPTransport
    private let configuration: GOGAuthConfiguration
    private let tokenStore: any GOGTokenStoring
    private let allowList: ImportAllowList
    private let now: @Sendable () -> Date
    /// Refresh this many seconds before real expiry.
    private let refreshLeeway: TimeInterval

    private var cached: GOGStoredToken?
    private var refreshTask: Task<GOGStoredToken, Error>?

    init(transport: HTTPTransport,
         configuration: GOGAuthConfiguration,
         tokenStore: any GOGTokenStoring,
         allowList: ImportAllowList = .gog,
         refreshLeeway: TimeInterval = 120,
         now: @Sendable @escaping () -> Date = { Date() }) {
        self.transport = transport
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.allowList = allowList
        self.refreshLeeway = refreshLeeway
        self.now = now
    }

    // MARK: - UI-facing sign-in surface (for the WKWebView bridge lane)

    /// The URL the login WebView loads first (PLAN §14.1).
    nonisolated var authorizationURL: URL { configuration.authorizationURL }

    /// Hosts the login WebView may navigate to (captcha host may be added by the UI).
    nonisolated var allowedNavigationHosts: [String] { configuration.allowedNavigationHosts }

    /// The pure redirect parser for the bridge (PLAN §14.1).
    nonisolated var redirectParser: GOGAuthRedirectParser {
        GOGAuthRedirectParser(redirectURI: configuration.redirectURI)
    }

    // MARK: - Session state

    /// Is there a stored refresh token (a session to use)?
    func hasSession() -> Bool {
        (cached ?? (try? tokenStore.loadToken())) != nil
    }

    /// Exchange an authorization `code` for tokens and persist them (PLAN §14.1).
    func completeSignIn(code: String) async throws {
        let token = try await exchange(grant: .authorizationCode(code))
        try persist(token)
    }

    /// A currently-valid access token, refreshing (single-flight) if near expiry.
    /// Throws ``ImportError/notAuthenticated`` when there is no session.
    func validAccessToken() async throws -> String {
        let stored = cached ?? (try? tokenStore.loadToken())
        cached = stored
        if let stored, stored.expiresAt.timeIntervalSince(now()) > refreshLeeway {
            return stored.accessToken
        }
        guard let refreshToken = stored?.refreshToken else {
            throw ImportError.notAuthenticated
        }
        return try await refresh(refreshToken).accessToken
    }

    /// Force a token refresh regardless of expiry — the 401 path (PLAN §14.1 rule 3).
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

    /// Sign out: forget and delete the tokens (PLAN §14.1).
    func signOut() throws {
        cached = nil
        try tokenStore.deleteToken()
    }

    /// Literal token strings to scrub from any persisted/logged text (PLAN §14.2).
    func redactionLiterals() -> [String] {
        guard let token = cached ?? (try? tokenStore.loadToken()) else { return [] }
        return [token.accessToken, token.refreshToken]
    }

    // MARK: - Token exchange / refresh

    private enum Grant {
        case authorizationCode(String)
        case refreshToken(String)
    }

    private func refresh(_ refreshToken: String) async throws -> GOGStoredToken {
        if let refreshTask { return try await refreshTask.value }
        let task = Task<GOGStoredToken, Error> { [self] in
            let token = try await exchange(grant: .refreshToken(refreshToken))
            try persist(token)
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func exchange(grant: Grant) async throws -> GOGStoredToken {
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "client_secret", value: configuration.clientSecret),
        ]
        switch grant {
        case .authorizationCode(let code):
            items.append(URLQueryItem(name: "grant_type", value: "authorization_code"))
            items.append(URLQueryItem(name: "code", value: code))
            items.append(URLQueryItem(name: "redirect_uri", value: configuration.redirectURI))
        case .refreshToken(let token):
            items.append(URLQueryItem(name: "grant_type", value: "refresh_token"))
            items.append(URLQueryItem(name: "refresh_token", value: token))
        }
        var components = URLComponents(url: configuration.tokenEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else { throw ImportError.notAuthenticated }
        try allowList.check(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            // A failed exchange/refresh means the session is not usable — sign in again.
            throw ImportError.notAuthenticated
        }
        guard let dto = try? JSONDecoder().decode(GOGTokenDTO.self, from: data) else {
            throw ImportError.notAuthenticated
        }
        return GOGStoredToken(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(dto.expiresIn)))
    }

    private func persist(_ token: GOGStoredToken) throws {
        cached = token
        try tokenStore.saveToken(token)
    }
}
