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

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

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
