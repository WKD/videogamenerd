import Foundation

/// Owns the Twitch app access token for IGDB (client-credentials flow). Caches the
/// token in memory until shortly before expiry, coalesces concurrent refreshes into a
/// single in-flight request, and exposes `forceRefresh()` for the client's
/// refresh-and-retry-once-on-401 path.
///
/// No Keychain dependency: credentials come from an injected closure (the UI lane
/// wires `KeychainStore` in next wave) and an optional `persist` closure lets a caller
/// stash the token if it ever wants to (also Keychain-free here).
actor IGDBTokenProvider {
    struct Token: Sendable, Equatable {
        var accessToken: String
        var expiresAt: Date
    }

    private let transport: HTTPTransport
    private let credentials: @Sendable () async -> IGDBCredentials?
    private let now: @Sendable () -> Date
    private let persist: (@Sendable (Token) async -> Void)?
    private let tokenURL: URL
    /// Refresh this many seconds before the real expiry, to avoid using a token that
    /// dies mid-request.
    private let refreshLeeway: TimeInterval

    private var cached: Token?
    private var refreshTask: Task<Token, Error>?

    init(
        transport: HTTPTransport,
        credentials: @Sendable @escaping () async -> IGDBCredentials?,
        tokenURL: URL = URL(string: "https://id.twitch.tv/oauth2/token")!,
        refreshLeeway: TimeInterval = 60,
        now: @Sendable @escaping () -> Date = { Date() },
        persist: (@Sendable (Token) async -> Void)? = nil
    ) {
        self.transport = transport
        self.credentials = credentials
        self.tokenURL = tokenURL
        self.refreshLeeway = refreshLeeway
        self.now = now
        self.persist = persist
    }

    /// A currently-valid access token, refreshing if needed. Concurrent callers share
    /// one refresh.
    func validToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > refreshLeeway {
            return cached.accessToken
        }
        return try await refresh().accessToken
    }

    /// Discard the cached token and fetch a fresh one (used after a 401).
    @discardableResult
    func forceRefresh() async throws -> String {
        cached = nil
        return try await refresh().accessToken
    }

    /// Seed a token from persistence (optional; never required).
    func seed(_ token: Token) {
        cached = token
    }

    // MARK: - Single-flight refresh

    private func refresh() async throws -> Token {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<Token, Error> { [self] in
            try await fetchToken()
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        cached = token
        if let persist {
            await persist(token)
        }
        return token
    }

    private func fetchToken() async throws -> Token {
        guard let creds = await credentials() else {
            throw IGDBError.missingCredentials
        }
        var components = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: creds.clientID),
            URLQueryItem(name: "client_secret", value: creds.secret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        // Send the credentials in the body (not the URL) so they never leak into a
        // URL-level log.
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery.map { Data($0.utf8) }

        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw IGDBError.http(status: response.statusCode, message: Self.trimmedBody(data))
        }
        let decoded: TwitchTokenResponse
        do {
            decoded = try JSONDecoder().decode(TwitchTokenResponse.self, from: data)
        } catch {
            throw IGDBError.decoding("token: \(error)")
        }
        return Token(
            accessToken: decoded.accessToken,
            expiresAt: now().addingTimeInterval(TimeInterval(decoded.expiresIn))
        )
    }

    private static func trimmedBody(_ data: Data) -> String {
        String(decoding: data.prefix(500), as: UTF8.self)
    }
}

private struct TwitchTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}
