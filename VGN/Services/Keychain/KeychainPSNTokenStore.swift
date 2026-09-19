import Foundation

/// Keychain-backed ``PSNTokenStoring`` (PLAN §13.1 rule 5): the PSN OAuth tokens are
/// persisted as **one JSON blob** under ``SecretKey/psnTokens`` (service = bundle id,
/// account `psn.tokens`) and never logged. The NPSSO is **never** persisted — only the
/// tokens it was exchanged for. A thin adapter over ``SecretStoring``, so the production
/// Keychain path and the in-memory test fake share one code path and ``PSNAuth`` stays
/// free of any Keychain dependency.
///
/// A corrupt/undecodable blob reads as "no session" (the user simply signs in again),
/// never a thrown error mid-flow.
struct KeychainPSNTokenStore: PSNTokenStoring {
    private let secrets: any SecretStoring
    private let key: SecretKey

    init(secrets: any SecretStoring, key: SecretKey = .psnTokens) {
        self.secrets = secrets
        self.key = key
    }

    func loadToken() throws -> PSNStoredToken? {
        guard let json = try secrets.string(for: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PSNStoredToken.self, from: data)
    }

    func saveToken(_ token: PSNStoredToken) throws {
        let data = try JSONEncoder().encode(token)
        try secrets.set(String(decoding: data, as: UTF8.self), for: key)
    }

    func deleteToken() throws {
        try secrets.set(nil, for: key)
    }
}
