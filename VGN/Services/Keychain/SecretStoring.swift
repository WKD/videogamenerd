import Foundation

/// Typed keys for the secrets VGN keeps in the Keychain (PLAN §5.1, §5.4).
/// The raw value is the Keychain account name.
enum SecretKey: String, CaseIterable, Sendable {
    case igdbClientID = "igdb.clientID"
    case igdbClientSecret = "igdb.clientSecret"
    // PSN access / refresh tokens are added here when the PSN lane lands.
}

/// A small, `Sendable` abstraction over secret storage so the UI, Settings and
/// (next wave) the services lane depend on the protocol, not the Keychain — and
/// tests run against an in-memory fake. `set(nil, for:)` deletes the item.
protocol SecretStoring: Sendable {
    func string(for key: SecretKey) throws -> String?
    func set(_ value: String?, for key: SecretKey) throws
}

extension SecretStoring {
    /// Convenience: does a non-empty secret exist for this key?
    func hasValue(for key: SecretKey) -> Bool {
        (try? string(for: key)).flatMap { $0 }.map { !$0.isEmpty } ?? false
    }
}

/// An in-memory `SecretStoring` for tests and previews. Never touches the
/// Keychain. Thread-safe via a lock so it satisfies `Sendable`.
final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SecretKey: String] = [:]

    init(seed: [SecretKey: String] = [:]) {
        storage = seed
    }

    func string(for key: SecretKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: String?, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage[key] = nil
        }
    }
}
