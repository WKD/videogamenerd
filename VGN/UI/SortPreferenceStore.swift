import Foundation

/// A persisted sort choice (field + direction) for one sidebar selection
/// (PLAN §8: "sort … persisted per sidebar selection").
struct SortSetting: Codable, Equatable, Sendable {
    var sort: LibrarySort
    var ascending: Bool
}

/// Per-selection sort persistence, keyed by ``SidebarSelection/id``.
protocol SortPreferenceStoring: Sendable {
    func sortSetting(for selectionID: String) -> SortSetting?
    func setSortSetting(_ setting: SortSetting, for selectionID: String)
}

/// `UserDefaults`-backed persistence: one JSON value per selection id, so the
/// chosen sort survives relaunch (PLAN §8/§10 "relaunch is instant").
struct UserDefaultsSortPreferences: SortPreferenceStoring {
    /// `UserDefaults` is internally synchronised but not `Sendable`-annotated.
    nonisolated(unsafe) let defaults: UserDefaults
    private let prefix = "VGNSort."

    init(defaults: UserDefaults = AppPreferences.defaults) {
        self.defaults = defaults
        Self.migrateLegacyKeys(in: defaults, prefix: prefix)
    }

    /// One-time id renames (PLAN §16 — the sidebar's "ROM Catalogue" row became the Vault's
    /// "Batocera ROMs" row, id `romCatalogue` → `vault:batocera`). Copies the persisted sort
    /// under the old id to the new one when the new key is unset, then removes the old key.
    /// Idempotent.
    static func migrateLegacyKeys(in defaults: UserDefaults, prefix: String) {
        let renames = [("romCatalogue", "vault:batocera")]
        for (old, new) in renames {
            let oldKey = prefix + old, newKey = prefix + new
            guard let data = defaults.data(forKey: oldKey) else { continue }
            if defaults.data(forKey: newKey) == nil { defaults.set(data, forKey: newKey) }
            defaults.removeObject(forKey: oldKey)
        }
    }

    func sortSetting(for selectionID: String) -> SortSetting? {
        guard let data = defaults.data(forKey: prefix + selectionID) else { return nil }
        return try? JSONDecoder().decode(SortSetting.self, from: data)
    }

    func setSortSetting(_ setting: SortSetting, for selectionID: String) {
        guard let data = try? JSONEncoder().encode(setting) else { return }
        defaults.set(data, forKey: prefix + selectionID)
    }
}

/// In-memory persistence (tests; also a safe default with no `UserDefaults`).
final class InMemorySortPreferences: SortPreferenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: SortSetting] = [:]
    init() {}
    func sortSetting(for selectionID: String) -> SortSetting? { lock.withLock { byID[selectionID] } }
    func setSortSetting(_ setting: SortSetting, for selectionID: String) {
        lock.withLock { byID[selectionID] = setting }
    }
}
