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
