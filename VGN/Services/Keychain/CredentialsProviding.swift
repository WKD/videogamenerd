import Foundation

/// The exact shape the services lane (IGDB client) consumes next wave (PLAN
/// §5.1). Implemented on top of any `SecretStoring`, so swapping the Keychain
/// for a fake in tests needs no change here.
protocol CredentialsProviding: Sendable {
    func igdbCredentials() async -> (clientID: String, secret: String)?
}

/// IGDB credentials backed by a `SecretStoring`. Returns nil unless both the
/// client id and secret are present and non-empty.
struct SecretsCredentialsProvider: CredentialsProviding {
    let store: any SecretStoring

    init(store: any SecretStoring) {
        self.store = store
    }

    func igdbCredentials() async -> (clientID: String, secret: String)? {
        guard
            let id = try? store.string(for: .igdbClientID), !id.isEmpty,
            let secret = try? store.string(for: .igdbClientSecret), !secret.isEmpty
        else { return nil }
        return (id, secret)
    }
}
