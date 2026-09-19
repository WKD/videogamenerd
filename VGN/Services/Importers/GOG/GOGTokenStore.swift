import Foundation

/// The GOG OAuth token as persisted (PLAN §14.1 — only tokens live in the Keychain,
/// never the password). `user_id` / `session_id` are deliberately **not** kept: they
/// are only used to redact the exchange response and then discarded.
struct GOGStoredToken: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

/// Keychain seam for the GOG token (PLAN §14.1 — service = bundle id, account `gog`).
/// GOGAuth depends on this, not on `SecretStoring` directly, so a fake drives tests
/// with no Keychain access. The production Keychain adapter (a one-liner over
/// `SecretStoring`) is the wiring lane's to add once a `gog` secret key exists — see
/// the hand-off.
protocol GOGTokenStoring: Sendable {
    func loadToken() throws -> GOGStoredToken?
    func saveToken(_ token: GOGStoredToken) throws
    func deleteToken() throws
}

/// In-memory `GOGTokenStoring` for tests and previews — never touches the Keychain.
final class InMemoryGOGTokenStore: GOGTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: GOGStoredToken?

    init(seed: GOGStoredToken? = nil) { self.token = seed }

    func loadToken() throws -> GOGStoredToken? { lock.withLock { token } }
    func saveToken(_ token: GOGStoredToken) throws { lock.withLock { self.token = token } }
    func deleteToken() throws { lock.withLock { token = nil } }
}
