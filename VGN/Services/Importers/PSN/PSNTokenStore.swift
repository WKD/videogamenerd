import Foundation

/// The PSN OAuth tokens as persisted (PLAN §13.1 rule 5 — only the tokens live in the
/// Keychain, never the NPSSO, password or the OAuth code). The refresh-token expiry
/// (~2 months) is kept so the UI can show "sign in again after…" and so a refresh is not
/// attempted with a dead refresh token.
struct PSNStoredToken: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var refreshExpiresAt: Date
    /// A random id minted at every interactive sign-in and kept across token refreshes.
    /// Every cached PSN response and probe marker is keyed by it, so responses fetched
    /// for one account can never be served to another (2026-09-20: after signing out of
    /// the test account and into the real one, the endpoint-only cache key handed the
    /// real account the test account's cached profile and empty lists). It identifies a
    /// login session, not the account, and is not a secret.
    var cacheScope: String

    init(accessToken: String, refreshToken: String, expiresAt: Date, refreshExpiresAt: Date,
         cacheScope: String = UUID().uuidString) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.cacheScope = cacheScope
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, refreshExpiresAt, cacheScope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        refreshExpiresAt = try c.decode(Date.self, forKey: .refreshExpiresAt)
        // Tokens stored before scopes existed get a fresh one (⇒ a cold cache, never a
        // wrong one). `PSNAuth.cacheScope()` persists it.
        cacheScope = try c.decodeIfPresent(String.self, forKey: .cacheScope) ?? UUID().uuidString
    }
}

/// Keychain seam for the PSN tokens (PLAN §13.1 — service = bundle id). ``PSNAuth``
/// depends on this, not on `SecretStoring` directly, so a fake drives tests with no
/// Keychain access.
protocol PSNTokenStoring: Sendable {
    func loadToken() throws -> PSNStoredToken?
    func saveToken(_ token: PSNStoredToken) throws
    func deleteToken() throws
}

/// In-memory `PSNTokenStoring` for tests and previews — never touches the Keychain.
final class InMemoryPSNTokenStore: PSNTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: PSNStoredToken?

    init(seed: PSNStoredToken? = nil) { self.token = seed }

    func loadToken() throws -> PSNStoredToken? { lock.withLock { token } }
    func saveToken(_ token: PSNStoredToken) throws { lock.withLock { self.token = token } }
    func deleteToken() throws { lock.withLock { token = nil } }
}
