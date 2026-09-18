import SwiftUI
import Observation

/// A keyboard intent routed from the grid to the view model. Kept as a value so
/// it can be tested without any UI.
enum LibraryKey: Hashable, Sendable {
    case tier(String)   // "S" "A" "B" "C" "D" "F"
    case clearTier      // "0"
    case markOwned      // "O"
    case markPlayed     // "P"

    /// Map a typed character to an intent, or nil if it isn't one we handle.
    init?(character: Character) {
        switch Character(character.uppercased()) {
        case "S", "A", "B", "C", "D", "F": self = .tier(String(character.uppercased()))
        case "0": self = .clearTier
        case "O": self = .markOwned
        case "P": self = .markPlayed
        default: return nil
        }
    }
}

/// The single `@MainActor @Observable` store behind the whole main window
/// (PLAN §8). Holds the selection, filter, loaded rows, counts, platforms and
/// grid/inspector chrome, and reads its data through `LibraryDataSource` so the
/// GRDB-backed source drops in next wave with a one-line change in the app.
@MainActor
@Observable
final class LibraryViewModel {
    // MARK: Loaded data (observed from the data source)
    private(set) var games: [GameSummary] = []
    private(set) var counts: SidebarCounts = .empty
    private(set) var platforms: [PlatformInfo] = []
    private(set) var tiers: [TierInfo] = []
    private(set) var genresInUse: [String] = []
    private(set) var decadesInUse: [Int] = []

    // MARK: UI state
    private(set) var selection: SidebarSelection
    private(set) var filter: LibraryFilter
    var selectedGameIDs: Set<Int64> = [] {
        didSet { refreshDetailObservation() }
    }
    /// The row shift-selection extends from.
    private(set) var selectionAnchor: Int64?

    /// Minimum grid cell width in points, driven by the toolbar size slider.
    var gridCellWidth: Double = 150
    static let minCellWidth: Double = 110
    static let maxCellWidth: Double = 230

    /// The live search field text. Debounced (~150 ms) into `filter.searchText`
    /// so each keystroke doesn't recompile/rerun the grid query (PLAN §8).
    var searchText: String = "" {
        didSet { scheduleSearchCommit() }
    }
    private var searchDebounceTask: Task<Void, Never>?

    var inspectorPresented: Bool = false
    /// True while the toolbar search field owns focus — key intents (S/A/…, O, P)
    /// are suppressed so typing a title never re-tiers the selection.
    var searchFieldFocused: Bool = false
    /// Placeholder Quick Add sheet flag until the palette lane builds the real
    /// one next wave.
    var quickAddPresented: Bool = false
    /// Bumped to ask the view to move keyboard focus into the search field (⌘F).
    private(set) var searchFocusRequests: Int = 0

    // MARK: Seams
    let dataSource: any LibraryDataSource
    let coverLoader: any CoverLoading

    /// The write-orchestration object (tier/owned/played/status/playtime/delete,
    /// banners, confirmations, undo). Nil in previews/tests that drive the
    /// closures directly. Held weakly — the app owns both this and the actions.
    weak var actions: LibraryActions?

    /// The window's undo manager, injected by `RootView`. Reversible intents
    /// (tier / played / status / playtime) register their inverse here.
    var undoManager: UndoManager?

    // MARK: Intent hooks (routed to `LibraryActions` by the app; log-only else)
    var onSetTier: (Set<Int64>, String?) -> Void
    var onSetOwned: (Set<Int64>, Bool) -> Void
    var onSetPlayed: (Set<Int64>, Bool) -> Void
    var onShowInspector: () -> Void
    var onQuickAdd: () -> Void
    /// Inspector "Refresh metadata" (wired by the app to the enrichment coordinator).
    var onRefreshMetadata: (Int64) -> Void = { _ in }
    /// Drop-an-image-to-set-cover (wired by the app to the cover store + store write).
    var onImportCover: (Int64, URL) -> Void = { _, _ in }

    // MARK: Non-blocking user feedback (PLAN §8 — errors never swallowed)
    /// The current transient banner, or nil. Auto-dismisses after a few seconds.
    var banner: LibraryBanner?
    /// A pending yes/no confirmation (orphan delete / last-copy removal).
    var pendingConfirmation: LibraryConfirmation?
    /// A pending "add a copy" flow needing a platform + format choice.
    var ownershipRequest: OwnershipRequest?
    /// A pending "remove which copies?" flow.
    var copyRemovalRequest: CopyRemovalRequest?

    // MARK: Inspector live detail (single selection)
    /// Full detail for the single selected game, kept live by an observation so
    /// the inspector updates itself after any write (PLAN §8).
    private(set) var selectedDetail: GameDetail?

    // MARK: Per-cell boxes (PLAN §9)
    private var cellModels: [Int64: GameCellModel] = [:]

    // MARK: Observation tasks
    private var countsTask: Task<Void, Never>?
    private var platformsTask: Task<Void, Never>?
    private var tiersTask: Task<Void, Never>?
    private var gamesTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?
    private var decadesTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?

    /// Bumped on every `restartGames` so a stale observation task's emission is
    /// dropped even if it arrives after the newer task started (latest wins).
    private var gamesGeneration = 0
    /// The game id the detail observation currently tracks (avoids re-subscribing
    /// when the same single game stays selected).
    private var observedDetailID: Int64?

    init(
        dataSource: any LibraryDataSource,
        coverLoader: any CoverLoading = NoopCoverLoader(),
        selection: SidebarSelection = .all
    ) {
        self.dataSource = dataSource
        self.coverLoader = coverLoader
        self.selection = selection
        self.filter = LibraryFilter(scope: selection)
        // Default intent hooks log so the keyboard/context-menu wiring is
        // observable in DEBUG without any DB. Replaced by the app next wave.
        self.onSetTier = { ids, letter in
            print("[VGN stub] setTier \(letter ?? "clear") for \(ids.count) game(s)")
        }
        self.onSetOwned = { ids, value in
            print("[VGN stub] setOwned \(value) for \(ids.count) game(s)")
        }
        self.onSetPlayed = { ids, value in
            print("[VGN stub] setPlayed \(value) for \(ids.count) game(s)")
        }
        self.onShowInspector = {}
        self.onQuickAdd = { print("[VGN stub] Quick Add requested (⌘N)") }
    }

    // MARK: Lifecycle

    /// Begin observing all four data streams. Idempotent — safe to call once
    /// from `.task`.
    func start() {
        guard countsTask == nil else { return }
        countsTask = Task { [dataSource] in
            for await value in dataSource.sidebarCounts() { self.counts = value }
        }
        platformsTask = Task { [dataSource] in
            for await value in dataSource.platformsInUse() { self.platforms = value }
        }
        tiersTask = Task { [dataSource] in
            for await value in dataSource.tiers() { self.tiers = value }
        }
        genresTask = Task { [dataSource] in
            for await value in dataSource.genresInUse() { self.genresInUse = value }
        }
        decadesTask = Task { [dataSource] in
            for await value in dataSource.decadesInUse() { self.decadesInUse = value }
        }
        restartGames()
    }

    func stop() {
        countsTask?.cancel(); countsTask = nil
        platformsTask?.cancel(); platformsTask = nil
        tiersTask?.cancel(); tiersTask = nil
        gamesTask?.cancel(); gamesTask = nil
        detailTask?.cancel(); detailTask = nil
        genresTask?.cancel(); genresTask = nil
        decadesTask?.cancel(); decadesTask = nil
    }

    private func restartGames() {
        gamesTask?.cancel()
        gamesGeneration &+= 1
        let generation = gamesGeneration
        let filter = self.filter
        gamesTask = Task { [dataSource] in
            for await rows in dataSource.games(filter: filter) {
                // Drop a stale task's late emission — the newest restart wins.
                if Task.isCancelled || generation != self.gamesGeneration { break }
                self.applyGames(rows)
            }
        }
    }

    /// Adopt tier definitions directly. The app feeds these from the `tiers()`
    /// observation in `start()`; exposed so tests can seed them without a live
    /// observation.
    func applyTiers(_ newTiers: [TierInfo]) { tiers = newTiers }

    /// Adopt a freshly-observed set of rows. `internal` so tests (and the live
    /// store next wave) can drive it directly.
    func applyGames(_ rows: [GameSummary]) {
        games = rows
        let ids = Set(rows.map(\.id))
        for row in rows {
            if let model = cellModels[row.id] {
                model.update(row)
            } else {
                cellModels[row.id] = GameCellModel(summary: row)
            }
        }
        for key in cellModels.keys where !ids.contains(key) {
            cellModels[key] = nil
        }
        selectedGameIDs.formIntersection(ids)
        if let anchor = selectionAnchor, !ids.contains(anchor) { selectionAnchor = nil }
    }

    /// (Re)subscribe the inspector's live detail to the single selected game.
    /// A single-selection change swaps the observation; zero/many clears it.
    private func refreshDetailObservation() {
        let single: Int64? = selectedGameIDs.count == 1 ? selectedGameIDs.first : nil
        guard single != observedDetailID else { return }
        observedDetailID = single
        detailTask?.cancel()
        guard let id = single else {
            selectedDetail = nil
            detailTask = nil
            return
        }
        if selectedDetail?.id != id { selectedDetail = nil }
        detailTask = Task { [dataSource] in
            for await detail in dataSource.gameDetailStream(id: id) {
                if Task.isCancelled || self.observedDetailID != id { break }
                self.selectedDetail = detail
            }
        }
    }

    // MARK: Cell boxes

    /// The stable observable box for a game id. Boxes are created in
    /// `applyGames`, so this is a read (never mutates state during view update).
    func cellModel(for id: Int64) -> GameCellModel {
        if let model = cellModels[id] { return model }
        let summary = games.first { $0.id == id } ?? GameSummary(id: id, title: "")
        return GameCellModel(summary: summary)
    }

    // MARK: Sidebar selection

    /// Bind this to `List(selection:)`. A nil (deselect) is ignored so the grid
    /// always has a scope.
    var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { self.selection },
            set: { self.select($0) }
        )
    }

    func select(_ newValue: SidebarSelection?) {
        guard let newValue, newValue != selection else { return }
        selection = newValue
        var f = filter
        f.scope = newValue
        // Scope change clears the independent platform facet and text so the
        // new list starts clean (matches romlord's behaviour).
        filter = f
        selectedGameIDs.removeAll()
        selectionAnchor = nil
        restartGames()
    }

    /// True when the current sidebar selection is a ranking destination (grid
    /// is replaced by a placeholder in those).
    var isRankingSelection: Bool {
        switch selection {
        case .tierBoard, .theTop, .duel: return true
        default: return false
        }
    }

    // MARK: Filter

    func setFilter(_ new: LibraryFilter) {
        guard new != filter else { return }
        filter = new
        // Keep the search field in sync when the filter's text is set
        // programmatically (e.g. "Clear filters"). The guard in the didSet
        // prevents a commit loop (text already equals the filter).
        if searchText != new.searchText { searchText = new.searchText }
        restartGames()
    }

    /// Debounce the search field into the filter (latest keystroke wins).
    private func scheduleSearchCommit() {
        searchDebounceTask?.cancel()
        let text = searchText
        guard text != filter.searchText else { return }
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, text == self.searchText else { return }
            guard text != self.filter.searchText else { return }
            var f = self.filter
            f.searchText = text
            self.setFilter(f)
        }
    }

    /// A binding to one field of the filter that re-runs the query on change.
    func filterBinding<T>(_ keyPath: WritableKeyPath<LibraryFilter, T>) -> Binding<T> {
        Binding(
            get: { self.filter[keyPath: keyPath] },
            set: { newValue in
                var f = self.filter
                f[keyPath: keyPath] = newValue
                self.setFilter(f)
            }
        )
    }

    // MARK: Grid selection maths

    private func index(of id: Int64) -> Int? { games.firstIndex { $0.id == id } }

    func selectOnly(_ id: Int64) {
        selectedGameIDs = [id]
        selectionAnchor = id
    }

    /// ⌘-click: toggle one row's membership.
    func toggle(_ id: Int64) {
        if selectedGameIDs.contains(id) {
            selectedGameIDs.remove(id)
        } else {
            selectedGameIDs.insert(id)
        }
        selectionAnchor = id
    }

    /// ⇧-click: select the contiguous range from the anchor to `id`.
    func extendSelection(to id: Int64) {
        guard let anchor = selectionAnchor,
              let a = index(of: anchor), let b = index(of: id) else {
            selectOnly(id)
            return
        }
        let range = a <= b ? a...b : b...a
        selectedGameIDs = Set(games[range].map(\.id))
        // Anchor stays put so further shift-clicks pivot around it.
    }

    /// Arrow-key move by `delta` rows in the current ordering; returns the newly
    /// focused id (for scroll-to).
    @discardableResult
    func moveSelection(by delta: Int) -> Int64? {
        guard !games.isEmpty else { return nil }
        let currentIndex: Int
        if let anchor = selectionAnchor, let i = index(of: anchor) {
            currentIndex = i
        } else if let first = selectedGameIDs.first, let i = index(of: first) {
            currentIndex = i
        } else {
            currentIndex = delta > 0 ? -1 : games.count
        }
        let next = min(max(currentIndex + delta, 0), games.count - 1)
        let id = games[next].id
        selectOnly(id)
        return id
    }

    func selectAll() {
        selectedGameIDs = Set(games.map(\.id))
    }

    func clearSelection() {
        selectedGameIDs.removeAll()
        selectionAnchor = nil
    }

    /// The single selected game, or nil when zero or many are selected.
    var selectedGame: GameSummary? {
        guard selectedGameIDs.count == 1, let id = selectedGameIDs.first else { return nil }
        return games.first { $0.id == id }
    }

    var selectedGames: [GameSummary] {
        games.filter { selectedGameIDs.contains($0.id) }
    }

    // MARK: Keyboard / context-menu intents (stubbed via hooks)

    /// Route a key intent. Returns true if it was handled (so the view can
    /// swallow the key). Suppressed while the search field is focused.
    @discardableResult
    func handleKey(_ key: LibraryKey) -> Bool {
        guard !searchFieldFocused, !selectedGameIDs.isEmpty else { return false }
        switch key {
        case .tier(let letter): onSetTier(selectedGameIDs, letter)
        case .clearTier: onSetTier(selectedGameIDs, nil)
        case .markOwned: onSetOwned(selectedGameIDs, true)
        case .markPlayed: onSetPlayed(selectedGameIDs, true)
        }
        return true
    }

    func setTier(_ letter: String?, for ids: Set<Int64>? = nil) {
        onSetTier(ids ?? selectedGameIDs, letter)
    }
    func setOwned(_ value: Bool, for ids: Set<Int64>? = nil) {
        onSetOwned(ids ?? selectedGameIDs, value)
    }
    func setPlayed(_ value: Bool, for ids: Set<Int64>? = nil) {
        onSetPlayed(ids ?? selectedGameIDs, value)
    }

    // MARK: Commands

    func toggleInspector() { inspectorPresented.toggle() }
    func showInspector() { inspectorPresented = true; onShowInspector() }
    func requestSearchFocus() { searchFocusRequests &+= 1 }
    func requestQuickAdd() { quickAddPresented = true; onQuickAdd() }

    /// Inspector "Refresh metadata" — re-fetch everything for one game (PLAN §6.1).
    func refreshMetadata(gameID: Int64) { onRefreshMetadata(gameID) }

    /// Manual cover from a dropped/chosen image file (PLAN §5.2 point 4).
    func importCover(gameID: Int64, from url: URL) { onImportCover(gameID, url) }

    // MARK: Empty states
    var isEmptyLibrary: Bool { counts.all == 0 }
    var isEmptyFilterResult: Bool { games.isEmpty && !isEmptyLibrary }

    // MARK: Non-blocking feedback

    /// Show a transient banner (auto-dismisses). Errors are surfaced here rather
    /// than swallowed (PLAN §8).
    func showBanner(_ message: String, kind: LibraryBanner.Kind = .info) {
        banner = LibraryBanner(message: message, kind: kind)
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        banner = nil
    }
}
