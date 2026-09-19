import Foundation

/// Persisted settings for the Batocera ROM catalogue (PLAN §15 phase 2). A thin namespace
/// over ``AppPreferences/defaults`` (so the unit-test host never reads the owner's real
/// preferences), mirroring the PSN latch pattern. Everything degrades quietly: an absent
/// share folder or override simply means "not configured / use the defaults".
enum BatoceraPreferences {
    static let shareFolderKey = "batocera.shareFolder"
    static let autoSyncKey = "batocera.autoSyncAtLaunch"
    static let skipListKey = "batocera.skipList"

    /// The chosen share root (the folder that contains `roms/`), or nil when never picked.
    static var shareFolderPath: String? {
        get { AppPreferences.defaults.string(forKey: shareFolderKey) }
        set {
            if let newValue { AppPreferences.defaults.set(newValue, forKey: shareFolderKey) }
            else { AppPreferences.defaults.removeObject(forKey: shareFolderKey) }
        }
    }

    static var shareFolderURL: URL? {
        shareFolderPath.map { URL(fileURLWithPath: $0) }
    }

    /// Auto-sync at launch when the share is mounted. Default **ON** (a local file read).
    static var autoSyncAtLaunch: Bool {
        get {
            // Absent ⇒ true (default on); an explicit false disables it.
            AppPreferences.defaults.object(forKey: autoSyncKey) as? Bool ?? true
        }
        set { AppPreferences.defaults.set(newValue, forKey: autoSyncKey) }
    }

    /// The editable skip list, or nil when the owner has never changed it (⇒ use the
    /// built-in defaults). Stored as a JSON string array.
    static var skipListOverride: [String]? {
        get {
            guard let raw = AppPreferences.defaults.string(forKey: skipListKey),
                  let data = raw.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return list
        }
        set {
            guard let newValue else { AppPreferences.defaults.removeObject(forKey: skipListKey); return }
            if let data = try? JSONEncoder().encode(newValue),
               let raw = String(data: data, encoding: .utf8) {
                AppPreferences.defaults.set(raw, forKey: skipListKey)
            }
        }
    }

    /// The skip list shown/edited in Settings (override, else the built-in defaults).
    static var effectiveSkipList: [String] {
        skipListOverride ?? BatoceraSystems.defaultSkipList
    }

    /// The skip set the sync uses (the effective list; arcade families are always skipped
    /// on top of it inside ``BatoceraSystems/classify(_:skip:)``).
    static var effectiveSkipSet: Set<String> {
        Set(effectiveSkipList.map { $0.lowercased() })
    }
}

/// A snapshot of the catalogue for the Settings status block and diagnostics (PLAN §15).
/// Never reads the share — purely the local `rom_catalog` counts.
struct BatoceraCatalogStatus: Sendable, Hashable {
    var totalEntries = 0
    var systemsCount = 0
    /// Promotion candidates not yet promoted / dismissed (played > 5 min or favourite).
    var candidatesWaiting = 0

    static let empty = BatoceraCatalogStatus()
}
