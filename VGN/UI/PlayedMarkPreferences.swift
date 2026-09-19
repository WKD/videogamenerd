import Foundation

/// Persists the last "Mark Played As" value the user chose (PLAN §8, owner
/// request), so ⇧M / the top-level menu item repeat it. Injectable, mirroring
/// ``SortPreferenceStoring`` — the app uses `UserDefaults`, tests an in-memory box.
protocol LastPlayedMarkStoring: Sendable {
    /// The last chosen mark, or `.played` on first launch.
    func lastPlayedMark() -> PlayedMark
    func setLastPlayedMark(_ mark: PlayedMark)
}

/// `UserDefaults`-backed persistence (survives relaunch). Reads/writes through
/// ``AppPreferences/defaults`` so the unit-test host never touches the owner's
/// real preferences.
struct UserDefaultsLastPlayedMarkPreferences: LastPlayedMarkStoring {
    /// `UserDefaults` is internally synchronised but not `Sendable`-annotated.
    nonisolated(unsafe) let defaults: UserDefaults
    private let key = "VGNLastPlayedMark"

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    func lastPlayedMark() -> PlayedMark {
        guard let raw = defaults.string(forKey: key),
              let mark = PlayedMark(storageKey: raw) else { return .played }
        return mark
    }

    func setLastPlayedMark(_ mark: PlayedMark) {
        defaults.set(mark.storageKey, forKey: key)
    }
}

/// In-memory persistence (tests; also a safe default with no `UserDefaults`).
final class InMemoryLastPlayedMarkPreferences: LastPlayedMarkStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var mark: PlayedMark
    init(_ initial: PlayedMark = .played) { self.mark = initial }
    func lastPlayedMark() -> PlayedMark { lock.withLock { mark } }
    func setLastPlayedMark(_ mark: PlayedMark) { lock.withLock { self.mark = mark } }
}
