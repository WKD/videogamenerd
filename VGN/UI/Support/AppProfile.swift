import Foundation

/// An isolated **profile** of the app, chosen with the launch argument
/// `-VGNProfile <name>` (owner request 2026-09-19: run the first live PSN steps against a
/// dedicated database that cannot affect the real library).
///
/// A profile is still *live* mode (real network, real files) but everything it persists is
/// separate from the default profile:
/// - data folder `~/Library/Application Support/VGN-<name>/` (own `vgn.sqlite`, covers,
///   thumbs, backups, dev import cache) — see ``AppPaths``;
/// - preferences in their own `UserDefaults` suite — see ``AppPreferences``;
/// - Keychain items under their own service (so test-account tokens never mix with the
///   real account's), except the IGDB credentials, which are read from the default
///   service when the profile has none — see ``ProfileSecretStore``.
/// No argument = the default profile = exactly the pre-existing behaviour.
enum AppProfile {
    /// The sanitised profile name, or nil for the default profile. Launch arguments live
    /// in `UserDefaults.standard`'s argument domain.
    static let name: String? = sanitise(UserDefaults.standard.string(forKey: "VGNProfile"))

    static var isDefault: Bool { name == nil }

    /// Letters, digits, `-` and `_` only, max 32 — it becomes part of a folder name, a
    /// defaults suite and a Keychain service.
    static func sanitise(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let allowed = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed)).prefix(32)
        return cleaned.isEmpty ? nil : String(cleaned)
    }

    static func folderName(base: String, profile: String?) -> String {
        profile.map { "\(base)-\($0)" } ?? base
    }

    static func defaultsSuiteName(bundleID: String, profile: String) -> String {
        "\(bundleID).profile.\(profile)"
    }

    static func keychainService(base: String, profile: String?) -> String {
        profile.map { "\(base).profile.\($0)" } ?? base
    }
}

/// Keychain access for a profile: every secret lives under the profile's own service,
/// but the IGDB credentials fall back to the default service for reading, so matching
/// works in a fresh profile without re-entering them. Writes always go to the profile.
struct ProfileSecretStore: SecretStoring {
    let profile: any SecretStoring
    let fallback: any SecretStoring
    static let sharedKeys: Set<SecretKey> = [.igdbClientID, .igdbClientSecret]

    func string(for key: SecretKey) throws -> String? {
        if let value = try profile.string(for: key), !value.isEmpty { return value }
        return Self.sharedKeys.contains(key) ? try fallback.string(for: key) : nil
    }

    func set(_ value: String?, for key: SecretKey) throws {
        try profile.set(value, for: key)
    }
}
