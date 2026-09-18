import Foundation
import Security

/// A `Sendable` wrapper over the Security framework's generic-password items
/// (PLAN §5.1). Service defaults to the bundle id `com.wkd.VGN`. Secrets are
/// never logged. Signed builds keep these items across rebuilds (PLAN §3).
struct KeychainStore: SecretStoring {
    let service: String

    init(service: String = "com.wkd.VGN") {
        self.service = service
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case dataEncoding

        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error (OSStatus \(status))"
            case .dataEncoding:
                return "Keychain value was not valid UTF-8"
            }
        }
    }

    private func baseQuery(for key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    func string(for key: SecretKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataEncoding
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func set(_ value: String?, for key: SecretKey) throws {
        // nil / empty deletes.
        guard let value, !value.isEmpty else {
            try delete(key)
            return
        }
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataEncoding
        }

        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Available without an unlock prompt while the app runs.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
