import Foundation

/// Keychain-backed ``GOGTokenStoring`` (PLAN §14.1): the GOG OAuth token is persisted
/// as **one JSON blob** under ``SecretKey/gogTokens`` (service = bundle id, account
/// `gog.tokens`) and never logged. A thin adapter over ``SecretStoring``, so the
/// production Keychain path and the in-memory test fake share one code path and the
/// GOG auth actor stays free of any Keychain dependency.
///
/// A corrupt/undecodable blob reads as "no session" (the user simply signs in again),
/// never a thrown error mid-flow.
struct KeychainGOGTokenStore: GOGTokenStoring {
    private let secrets: any SecretStoring
    private let key: SecretKey

    init(secrets: any SecretStoring, key: SecretKey = .gogTokens) {
        self.secrets = secrets
        self.key = key
    }

    func loadToken() throws -> GOGStoredToken? {
        guard let json = try secrets.string(for: key),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GOGStoredToken.self, from: data)
    }

    func saveToken(_ token: GOGStoredToken) throws {
        let data = try JSONEncoder().encode(token)
        try secrets.set(String(decoding: data, as: UTF8.self), for: key)
    }

    func deleteToken() throws {
        try secrets.set(nil, for: key)
    }
}
