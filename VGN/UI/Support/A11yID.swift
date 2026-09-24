import Foundation

/// Stable, namespaced accessibility identifiers for the views the on-demand UI
/// smoke suite drives (hardening pass, `docs/uitests.md`). Setting them via
/// `.accessibilityIdentifier(…)` also improves real VoiceOver navigation.
///
/// The test target keeps a byte-for-byte copy of these strings in
/// `VGNUITests/A11yIdentifiers.swift` (a UI-test bundle cannot import the app),
/// so keep the two in sync when adding an identifier.
enum A11yID {
    // Sidebar
    static let sidebarPrefix = "sidebar.row."
    static func sidebarRow(_ id: String) -> String { "sidebar.row.\(id)" }

    // Toolbar
    static let toolbarSearch = "toolbar.search"
    static let toolbarInspector = "toolbar.inspector"
    static let toolbarAdd = "toolbar.add"
    static let toolbarFilterTier = "toolbar.filter.tier"
    static let toolbarFilterStatus = "toolbar.filter.status"

    // Grid
    static let grid = "grid"
    static func gridCell(_ id: Int64) -> String { "grid.cell.\(id)" }

    // Filter chips
    static let filterChips = "filter.chips"
    static func filterChip(_ kind: String) -> String { "filter.chip.\(kind)" }
    static let filterClearAll = "filter.clearAll"
    static let filterCount = "filter.count"

    // Inspector
    static let inspector = "inspector"
    static let inspectorPlayedToggle = "inspector.played"
    static let inspectorStatus = "inspector.status"
    static let inspectorPlaytimeField = "inspector.playtime"
    static let inspectorTierChip = "inspector.tierChip"
    static let inspectorHoldsUp = "inspector.holdsUp"

    // Quick Add
    static let quickAddField = "quickadd.field"
    static let quickAddPanel = "quickadd.panel"
    static let quickAddOfflineHint = "quickadd.offlineHint"
    static func quickAddRow(_ n: Int) -> String { "quickadd.row.\(n)" }
    static let quickAddManualRow = "quickadd.row.manual"
    static let quickAddOwnedState = "quickadd.state.owned"
    static let quickAddPlayedState = "quickadd.state.played"
    static let quickAddFormatState = "quickadd.state.format"
    static let quickAddPlatform = "quickadd.state.platform"

    // Duel
    static let duelLeft = "duel.left"
    static let duelRight = "duel.right"
    static let duelProgress = "duel.progress"
    static let duelEmpty = "duel.empty"
    static let duelModePicker = "duel.modePicker"

    // Triage
    static let triageCover = "triage.cover"
    static let triageProgress = "triage.progress"
    static let triageEmpty = "triage.empty"

    // Tier Board / The Top
    static let tierBoard = "tierboard"
    static func tierBoardRow(_ letter: String) -> String { "tierboard.row.\(letter)" }
    static let theTop = "thetop"
    static func topRow(_ id: Int64) -> String { "top.row.\(id)" }
    static let topExport = "top.export"

    // Play Next
    static let playNextHero = "playnext.hero"
    static let playNextEmpty = "playnext.empty"
    static func playNextBracket(_ n: Int) -> String { "playnext.bracket.\(n)" }
    static let playNextAskClaude = "playnext.askClaude"
    static let playNextReroll = "playnext.reroll"
    static let playNextBracketRange = "playnext.bracketRange"

    // Scan
    static let scanSheet = "scan.sheet"
    static let scanAddButton = "scan.addButton"
    static let scanUsageNotice = "scan.usageNotice"
    static let scanClose = "scan.close"

    // Settings
    static let settingsTabGeneral = "settings.tab.general"
    static let settingsTabAccounts = "settings.tab.accounts"
    static let settingsTabPhotoScan = "settings.tab.photoscan"
    static let settingsClaudePath = "settings.photoscan.claudePath"
    static let settingsCheck = "settings.photoscan.check"
}
