import SwiftUI
import Observation

/// A keyboard intent routed from the grid to the view model. Kept as a value so
/// it can be tested without any UI.
enum LibraryKey: Hashable, Sendable {
    case tier(String)   // "S" "A" "B" "C" "D" "F"
    case clearTier      // "0"
    case markOwned      // "O"
    case markPlayed     // "P"
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
    /// Per-source present-entry counts of **The Vault** (PLAN §16). A **separate** observation
    /// from the library counts — a Vault write never disturbs the library's counts stream, and
    /// these numbers never enter `SidebarCounts`. Drives the THE VAULT section's two rows
    /// (Batocera ROMs / PS Plus), each shown only when > 0, and their badges.
    private(set) var vaultCounts: VaultSourceCounts = VaultSourceCounts()

    // MARK: UI state
    private(set) var selection: SidebarSelection
    private(set) var filter: LibraryFilter
    var selectedGameIDs: Set<Int64> = [] {
        didSet { refreshDetailObservation() }
    }
    /// The row shift-selection extends from.
    private(set) var selectionAnchor: Int64?
    /// The moving end of a shift-arrow / shift-click range (pivots on the anchor).
    private var selectionCursor: Int64?

    // Type-to-select state (PLAN §8). See `applyGridAction`.
    private var typeBuffer: String = ""
    private var lastTypeAt: Date?
    /// How long after a type-to-select keystroke further letters keep extending the
    /// same buffer ("m" then "e" → "me"). ~1 s.
    let typeSelectWindow: TimeInterval = 1.0

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
    /// Bumped to ask the grid to take keyboard focus (↓ from the search field).
    private(set) var gridFocusRequests: Int = 0
    /// A query to prefill Quick Add with (empty-result "Add … with Quick Add").
    private var quickAddPrefill: String?

    // MARK: Seams
    let dataSource: any LibraryDataSource
    let coverLoader: any CoverLoading
    /// Per-sidebar-selection sort persistence (PLAN §8).
    private let sortPreferences: any SortPreferenceStoring
    /// Persistence for the last "Mark Played As" value (⇧M / menu repeat, PLAN §8).
    private let playedMarkPreferences: any LastPlayedMarkStoring
    /// Persistence for the owner's weekly play pace (drives the "By Length" shelves).
    private let playPacePreferences: any PlayPacePreferenceStoring

    /// The shared weekly-play-pace controller (owner request 2026-09-19). Behind the
    /// sidebar "By Length" header popover; Settings ▸ General edits the same store.
    /// A commit re-runs the grid + counts through ``applyPace(_:)``.
    let paceModel: PlayPaceModel

    /// The last-chosen "Mark Played As" value, repeated by ⇧M and the top-level
    /// "Mark as ‹Last›" menu item. Read by the grid context menu and the menu-bar
    /// commands; written only from an action (never a body/menu builder).
    private(set) var lastPlayedMark: PlayedMark

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
    /// Inspector "Remove custom cover" — clears the hand-picked cover + marker and
    /// re-enqueues the cover job (wired by the app).
    var onRemoveCover: (Int64) -> Void = { _ in }
    /// Open the compilation editor for a product (wired by the app to build a
    /// ``CompilationEditorModel`` and present it — PLAN §5.1).
    var onEditCompilation: (Int64) -> Void = { _ in }
    /// "Group as compilation…" from the current selection (wired by the app).
    var onGroupAsCompilation: (Set<Int64>) -> Void = { _ in }
    /// "Mark Played As" for a set of games (wired by the app to ``LibraryActions``).
    var onMarkPlayed: (Set<Int64>, PlayedMark) -> Void = { _, _ in }
    /// "Link to IGDB…" / "Change IGDB Match…" for one game (wired by the app to the
    /// reconcile presenter — PLAN §5.1).
    var onLinkToIGDB: (Int64) -> Void = { _ in }
    /// "Expand Bundle into Games…" for one game linked to an IGDB bundle (wired to the
    /// reconcile presenter — PLAN §5.1 repair path).
    var onExpandBundle: (Int64) -> Void = { _ in }

    // MARK: Non-blocking user feedback (PLAN §8 — errors never swallowed)
    /// The current transient banner, or nil. Auto-dismisses after a few seconds.
    var banner: LibraryBanner?
    /// The handler for a banner that carries an `actionTitle` (e.g. Batocera "Review…",
    /// PLAN §15). Kept off the `Equatable`/`Sendable` banner value.
    @ObservationIgnored private var bannerAction: (@MainActor () -> Void)?
    /// The handler for a banner's optional **second** action (kept off the value type).
    @ObservationIgnored private var bannerSecondaryAction: (@MainActor () -> Void)?
    /// A pending yes/no confirmation (orphan delete / last-copy removal).
    var pendingConfirmation: LibraryConfirmation?
    /// A pending "add a copy" flow needing a platform + format choice.
    var ownershipRequest: OwnershipRequest?
    /// A pending ask-once "Mark N Games as Owned" batch sheet (PLAN §8). Set only
    /// from an action handler, never a body/menu builder.
    var batchOwnershipRequest: BatchOwnershipModel?
    /// A pending "remove which copies?" flow.
    var copyRemovalRequest: CopyRemovalRequest?
    /// The compilation editor sheet's model, or nil (PLAN §5.1). Set by the app's
    /// `onEditCompilation` hook, which builds the model with the store + catalog.
    var compilationEditor: CompilationEditorModel?
    /// A pending "Group as compilation…" flow (title + platform + format).
    var groupCompilationRequest: GroupCompilationRequest?
    /// The "Choose Cover…" sheet's model while presented (PLAN §5.2 step 4). Shared
    /// by the inspector button and the grid context menu; a single `.sheet` in
    /// `RootView` presents it.
    var chooseCoverRequest: ChooseCoverModel?

    // MARK: Inspector live detail (single selection)
    /// Full detail for the single selected game, kept live by an observation so
    /// the inspector updates itself after any write (PLAN §8).
    private(set) var selectedDetail: GameDetail?

    /// The single selected game's live derived-score line ("9.6 · #4 overall") —
    /// re-emitted after any duel / drag / divider move (PLAN §7). Nil for an
    /// unranked or unselected game.
    private(set) var selectedScoreLine: DerivedScoreLine?

    /// Every tiered game's live derived 1–10 score, for the grid badge tooltip
    /// ("S — Masterpiece · 9.4"). Fed by a single library-wide observation; assigned
    /// only when it actually changes so unrelated writes don't re-render the grid.
    private(set) var scoresByGameID: [Int64: DerivedScoreValue] = [:]

    // MARK: Per-cell boxes (PLAN §9)
    private var cellModels: [Int64: GameCellModel] = [:]

    // MARK: Observation tasks
    private var countsTask: Task<Void, Never>?
    private var platformsTask: Task<Void, Never>?
    private var tiersTask: Task<Void, Never>?
    private var gamesTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var scoreLineTask: Task<Void, Never>?
    private var scoresTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?
    private var decadesTask: Task<Void, Never>?
    private var vaultCountsTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?

    /// Bumped on every `restartGames` so a stale observation task's emission is
    /// dropped even if it arrives after the newer task started (latest wins).
    private var gamesGeneration = 0
    /// The game id the detail observation currently tracks (avoids re-subscribing
    /// when the same single game stays selected).
    private var observedDetailID: Int64?

    /// After a played-mark that may drop games from the current scope (e.g.
    /// Backlog), where to move the selection once the grid refreshes without them.
    /// Consumed by the next ``applyGames`` that actually removes them (PLAN §8).
    private var pendingReselect: (removed: Set<Int64>, vacatedIndex: Int)?

    /// Clock for the type-to-select window (injectable so tests can control it).
    private let now: () -> Date

    init(
        dataSource: any LibraryDataSource,
        coverLoader: any CoverLoading = NoopCoverLoader(),
        selection: SidebarSelection = .all,
        sortPreferences: any SortPreferenceStoring = UserDefaultsSortPreferences(),
        playedMarkPreferences: any LastPlayedMarkStoring = UserDefaultsLastPlayedMarkPreferences(),
        playPacePreferences: any PlayPacePreferenceStoring = UserDefaultsPlayPacePreferences(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.dataSource = dataSource
        self.coverLoader = coverLoader
        self.sortPreferences = sortPreferences
        self.playedMarkPreferences = playedMarkPreferences
        self.playPacePreferences = playPacePreferences
        let paceModel = PlayPaceModel(store: playPacePreferences)
        self.paceModel = paceModel
        self.lastPlayedMark = playedMarkPreferences.lastPlayedMark()
        self.now = now
        self.selection = selection
        let initialSort = sortPreferences.sortSetting(for: selection.id)
        let fallbackSort = Self.defaultSort(for: selection)
        self.filter = LibraryFilter(
            scope: selection,
            playPace: paceModel.pace,
            playStyle: paceModel.style,
            sort: initialSort?.sort ?? fallbackSort,
            ascending: initialSort?.ascending ?? (initialSort?.sort ?? fallbackSort).defaultAscending
        )
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
        // Committing a pace (from the sidebar popover or Settings) re-runs the grid +
        // counts. Weak self so the model never keeps the view model alive.
        self.paceModel.onCommit = { [weak self] pace in self?.applyPace(pace) }
        self.paceModel.onStyleCommit = { [weak self] style in self?.applyStyle(style) }
    }

    /// The default sort for a freshly-selected scope with no persisted choice: the
    /// "By Length" scopes default to Length (shortest first — PLAN §8); Title else.
    static func defaultSort(for selection: SidebarSelection) -> LibrarySort {
        switch selection {
        case .length, .unmeasured: return .length
        default: return .title
        }
    }

    /// The owner's weekly play pace, exposed as plain API for a later Play Next
    /// alignment (PLAN §7b — the recommendation engine could weight time-fit to this).
    var playPace: PlayPace { paceModel.pace }
    /// Whether the owner has set a pace at least once (drives the first-use CTA).
    var hasChosenPace: Bool { paceModel.hasChosen }

    /// The "By Length" shelf last selected in the sidebar, awaiting a Play Next open
    /// (owner request 2026-09-19: preselect the matching bracket). Set from ``select``,
    /// read once by ``consumePlayNextBracketHint()``.
    private var pendingPlayNextShelfHint: LengthShelf?

    /// Consume the one-shot sidebar → Play Next bracket hint (called from Play Next's
    /// `start()`, never a body). Returns the last-selected "By Length" shelf, once.
    func consumePlayNextBracketHint() -> LengthShelf? {
        defer { pendingPlayNextShelfHint = nil }
        return pendingPlayNextShelfHint
    }

    /// Adopt a new weekly play pace: update the filter (so the grid re-runs for a "By
    /// Length" scope) and re-subscribe the counts observation with the new shelf
    /// bounds. Treated like a filter change — one grid restart, one counts
    /// re-subscribe, no loop. Selection is preserved (``applyGames`` intersects).
    func applyPace(_ pace: PlayPace) {
        guard pace != filter.playPace else { return }
        var f = filter
        f.playPace = pace
        setFilter(f)       // one grid restart (the filter changed)
        restartCounts()    // re-subscribe the single counts observation with new bounds
    }

    /// Adopt a new play style: update the filter (so a length-dependent grid — the "By
    /// Length" scopes, the Length sort, the Playtime filter's unplayed fallback —
    /// re-runs) and re-subscribe the counts with the new personal length. Treated like
    /// a filter change: one grid restart, one counts re-subscribe (owner request
    /// 2026-09-19).
    func applyStyle(_ style: PlayStyle) {
        guard style != filter.playStyle else { return }
        var f = filter
        f.playStyle = style
        setFilter(f)
        restartCounts()
    }

    // MARK: Lifecycle

    /// Begin observing all four data streams. Idempotent — safe to call once
    /// from `.task`.
    func start() {
        guard countsTask == nil else { return }
        restartCounts()
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
        vaultCountsTask = Task { [dataSource] in
            for await value in dataSource.vaultSourceCounts() {
                if value != self.vaultCounts { self.vaultCounts = value }
            }
        }
        scoresTask = Task { [dataSource] in
            for await value in dataSource.scoresStream() {
                // Assign only on a real change so an unrelated write (that leaves
                // every score untouched) never re-renders the grid cells.
                if value != self.scoresByGameID { self.scoresByGameID = value }
            }
        }
        restartGames()
    }

    func stop() {
        countsTask?.cancel(); countsTask = nil
        platformsTask?.cancel(); platformsTask = nil
        tiersTask?.cancel(); tiersTask = nil
        gamesTask?.cancel(); gamesTask = nil
        detailTask?.cancel(); detailTask = nil
        scoreLineTask?.cancel(); scoreLineTask = nil
        scoresTask?.cancel(); scoresTask = nil
        genresTask?.cancel(); genresTask = nil
        decadesTask?.cancel(); decadesTask = nil
        vaultCountsTask?.cancel(); vaultCountsTask = nil
    }

    /// (Re)subscribe the single sidebar-counts observation with the current pace's
    /// shelf bounds and the current play style's personal length. One observation —
    /// never a second (PLAN §8). Re-run on a pace or style change.
    private func restartCounts() {
        countsTask?.cancel()
        let pace = paceModel.pace
        let style = paceModel.style
        countsTask = Task { [dataSource] in
            for await value in dataSource.sidebarCounts(pace: pace, style: style) { self.counts = value }
        }
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
        consumeReselectPlan(newIDs: ids, rows: rows)
    }

    /// After a played-mark, if the marked games have now left this scope (e.g.
    /// Backlog), move the selection to whatever occupies the first vacated
    /// position, resetting the anchor/cursor. If they are all still present (a
    /// scope like All/Owned that keeps played games), cancel the plan and leave
    /// the selection be.
    private func consumeReselectPlan(newIDs: Set<Int64>, rows: [GameSummary]) {
        guard let plan = pendingReselect else { return }
        guard plan.removed.isDisjoint(with: newIDs) else {
            // Not (all) removed yet → this scope keeps them; nothing to reselect.
            if plan.removed.isSubset(of: newIDs) { pendingReselect = nil }
            return
        }
        pendingReselect = nil
        guard selectedGameIDs.isEmpty else { return }
        if rows.isEmpty {
            clearSelection()
        } else {
            selectOnly(rows[min(plan.vacatedIndex, rows.count - 1)].id)
        }
    }

    /// (Re)subscribe the inspector's live detail to the single selected game.
    /// A single-selection change swaps the observation; zero/many clears it.
    private func refreshDetailObservation() {
        let single: Int64? = selectedGameIDs.count == 1 ? selectedGameIDs.first : nil
        guard single != observedDetailID else { return }
        observedDetailID = single
        detailTask?.cancel()
        scoreLineTask?.cancel()
        guard let id = single else {
            selectedDetail = nil
            selectedScoreLine = nil
            detailTask = nil
            scoreLineTask = nil
            return
        }
        if selectedDetail?.id != id { selectedDetail = nil }
        selectedScoreLine = nil
        detailTask = Task { [dataSource] in
            for await detail in dataSource.gameDetailStream(id: id) {
                if Task.isCancelled || self.observedDetailID != id { break }
                self.selectedDetail = detail
            }
        }
        scoreLineTask = Task { [dataSource] in
            for await line in dataSource.scoreLineStream(for: id) {
                if Task.isCancelled || self.observedDetailID != id { break }
                self.selectedScoreLine = line
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
        // Remember a "By Length" shelf so opening Play Next next preselects the matching
        // bracket (a one-shot hint, consumed by ``consumePlayNextBracketHint()``).
        if case let .length(shelf) = newValue { pendingPlayNextShelfHint = shelf }
        selection = newValue
        var f = filter
        f.scope = newValue
        // Restore this selection's persisted sort (PLAN §8: "sort … persisted per
        // sidebar selection"); fall back to this scope's default sort + direction
        // (the "By Length" scopes default to Length ascending).
        let setting = sortPreferences.sortSetting(for: newValue.id)
        let fallback = Self.defaultSort(for: newValue)
        f.sort = setting?.sort ?? fallback
        f.ascending = setting?.ascending ?? (setting?.sort ?? fallback).defaultAscending
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

    /// True when the sidebar has Play Next selected (grid is replaced by the
    /// recommendation view — a placeholder until a later wave, PLAN §7b).
    var isPlayNextSelection: Bool { selection == .playNext }

    /// True when the sidebar has a Vault source selected (the grid is replaced by the separate
    /// Vault browser, PLAN §16).
    var isVaultSelection: Bool { if case .vault = selection { return true }; return false }

    /// True when the sidebar has "Bundles to Expand" selected — the grid shows a slim
    /// explanatory header above it (PLAN §5.1).
    var isBundlesToExpandSelection: Bool { selection == .bundlesToExpand }

    /// The selected Vault source, or nil when the selection is not a Vault row.
    var selectedVaultSource: VaultSource? {
        if case .vault(let source) = selection { return source }
        return nil
    }

    // MARK: Filter

    func setFilter(_ new: LibraryFilter) {
        guard new != filter else { return }
        let sortChanged = new.sort != filter.sort || new.ascending != filter.ascending
        filter = new
        // Persist the sort choice for the current selection (PLAN §8).
        if sortChanged {
            sortPreferences.setSortSetting(
                SortSetting(sort: new.sort, ascending: new.ascending), for: selection.id)
        }
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

    // MARK: Filter chips (PLAN §8)

    /// The active-filter chips shown under the toolbar, grouped by kind.
    var filterChips: [FilterChip] {
        LibraryFilterChips.chips(for: filter, tiers: tiers, platformShort: PlatformLabels.short)
    }

    /// Remove one chip's value from the filter (re-runs the query).
    func removeFilterChip(_ chip: FilterChip) {
        setFilter(LibraryFilterChips.removing(chip, from: filter))
    }

    /// Clear every active facet (search included), keeping scope + sort.
    func clearAllFilters() {
        setFilter(LibraryFilterChips.cleared(filter))
    }

    /// Choose the sort field. Changing the field resets the direction to that
    /// field's natural default (e.g. Playtime → most-played first); the direction
    /// toggle then overrides it. Both persist per selection.
    func setSort(_ sort: LibrarySort) {
        guard sort != filter.sort else { return }
        var f = filter
        f.sort = sort
        f.ascending = sort.defaultAscending
        setFilter(f)
    }

    /// Binding for the sort Picker (resets direction to the field's default).
    var sortBinding: Binding<LibrarySort> {
        Binding(get: { self.filter.sort }, set: { self.setSort($0) })
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
        selectionCursor = id
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
        selectionCursor = id
        // Anchor stays put so further shift-clicks pivot around it.
    }

    /// ⇧-arrow: extend the selection by `delta` rows from the moving cursor,
    /// pivoting on the anchor. Returns the new cursor id (for scroll-to).
    @discardableResult
    func extendSelection(by delta: Int) -> Int64? {
        guard !games.isEmpty else { return nil }
        let anchorIdx = selectionAnchor.flatMap(index(of:)) ?? 0
        let cursorIdx = (selectionCursor ?? selectionAnchor).flatMap(index(of:)) ?? anchorIdx
        let nextIdx = min(max(cursorIdx + delta, 0), games.count - 1)
        let cursorID = games[nextIdx].id
        selectionCursor = cursorID
        let lo = min(anchorIdx, nextIdx), hi = max(anchorIdx, nextIdx)
        selectedGameIDs = Set(games[lo...hi].map(\.id))
        if selectionAnchor == nil { selectionAnchor = games[anchorIdx].id }
        return cursorID
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
        selectionCursor = nil
    }

    // MARK: Grid one-key actions vs type-to-select (PLAN §7/§8)

    /// Apply a routed grid keystroke (see ``GridKeyRouter``). Returns an id to
    /// scroll to (a type-to-select jump) or nil (a tier/ownership action, or
    /// nothing to do). Suppressed while the search field owns focus.
    ///
    /// The routing is deterministic and lives in the pure ``GridKeyRouter``:
    /// plain letters always type-to-select; the tier/owned/played actions need ⇧
    /// (`⇧S…⇧F`, `⇧O`, `⇧P`); plain `0` clears the tier. So a type-to-select of a
    /// title starting with a tier letter is never eaten by an action.
    @discardableResult
    func applyGridAction(_ action: GridKeyAction) -> Int64? {
        guard !searchFieldFocused else { return nil }
        switch action {
        case .tier(let letter):
            handleKey(.tier(letter)); return nil
        case .clearTier:
            handleKey(.clearTier); return nil
        case .toggleOwned:
            toggleOwnedForSelection(); return nil
        case .togglePlayed:
            togglePlayedForSelection(); return nil
        case .markPlayedAsLast:
            applyLastPlayedMark(); return nil
        case .typeSelect(let character):
            return isTypeBufferActive() ? appendTypeSelect(character)
                                        : startTypeSelect(character)
        }
    }

    /// ⇧O — toggle owned across the whole selection: if every selected game is
    /// already owned, un-own; otherwise mark owned. (Un-owning may orphan a game;
    /// ``LibraryActions`` surfaces the confirmation.)
    private func toggleOwnedForSelection() {
        guard !selectedGameIDs.isEmpty else { return }
        let sel = selectedGames
        guard !sel.isEmpty else { return }
        onSetOwned(selectedGameIDs, !sel.allSatisfy(\.owned))
    }

    /// ⇧P — toggle played across the whole selection (mirrors ``toggleOwnedForSelection``).
    private func togglePlayedForSelection() {
        guard !selectedGameIDs.isEmpty else { return }
        let sel = selectedGames
        guard !sel.isEmpty else { return }
        onSetPlayed(selectedGameIDs, !sel.allSatisfy(\.played))
    }

    // MARK: Mark Played As (PLAN §8, owner request 2026-09-19)

    /// True when the current sidebar destination shows the library grid (so the
    /// menu-bar "Mark Played" commands are enabled). False for the ranking / Play
    /// Next destinations, which replace the grid.
    var isLibraryGridDestination: Bool { !isRankingSelection && !isPlayNextSelection }

    /// Apply a played-mark to a set of games: remember it as the new "last" value,
    /// plan a sensible reselection if this scope will drop the games, then dispatch
    /// the write (undo + banner live in ``LibraryActions``). Called from the grid
    /// context menu and the menu bar — never a body/menu *builder*.
    func markPlayed(_ ids: Set<Int64>, as mark: PlayedMark) {
        guard !ids.isEmpty else { return }
        setLastPlayedMark(mark)
        planReselection(removing: ids)
        onMarkPlayed(ids, mark)
    }

    /// ⇧M / menu "Mark as ‹Last›": repeat the last mark on the current selection.
    /// Suppressed (via ``applyGridAction``) while the search field owns focus.
    func applyLastPlayedMark() {
        guard !selectedGameIDs.isEmpty else { return }
        markPlayed(selectedGameIDs, as: lastPlayedMark)
    }

    /// Record the chosen mark as the repeat value (persisted). A no-op when it is
    /// already current (so the top-level repeat item costs no write).
    func setLastPlayedMark(_ mark: PlayedMark) {
        guard mark != lastPlayedMark else { return }
        lastPlayedMark = mark
        playedMarkPreferences.setLastPlayedMark(mark)
    }

    /// Snapshot the first vacated position among `ids` in the current ordering, so
    /// ``consumeReselectPlan`` can move the selection there once the grid refreshes.
    private func planReselection(removing ids: Set<Int64>) {
        let indices = ids.compactMap { id in games.firstIndex { $0.id == id } }
        guard let first = indices.min() else { pendingReselect = nil; return }
        pendingReselect = (ids, first)
    }

    /// Test/inspection: whether a type-to-select buffer is currently active.
    func isTypeBufferActive() -> Bool {
        guard let last = lastTypeAt else { return false }
        return now().timeIntervalSince(last) < typeSelectWindow
    }

    private func startTypeSelect(_ ch: Character) -> Int64? {
        typeBuffer = String(ch)
        lastTypeAt = now()
        return jumpToBuffer()
    }

    private func appendTypeSelect(_ ch: Character) -> Int64? {
        typeBuffer.append(ch)
        lastTypeAt = now()
        return jumpToBuffer()
    }

    /// Select the first game whose title matches the buffer prefix (accent- and
    /// case-insensitive), returning its id for scroll-to.
    private func jumpToBuffer() -> Int64? {
        let needle = TitleNormalizer.normalize(typeBuffer, level: .fold)
        guard !needle.isEmpty else { return nil }
        guard let match = games.first(where: {
            TitleNormalizer.normalize($0.title, level: .fold).hasPrefix(needle)
        }) else { return nil }
        selectOnly(match.id)
        return match.id
    }

    /// The single selected game, or nil when zero or many are selected.
    var selectedGame: GameSummary? {
        guard selectedGameIDs.count == 1, let id = selectedGameIDs.first else { return nil }
        return games.first { $0.id == id }
    }

    var selectedGames: [GameSummary] {
        games.filter { selectedGameIDs.contains($0.id) }
    }

    /// The loaded summaries for a set of ids — the games a context-menu action targets, so
    /// its mixed-state menu (tier / format / played / owned) reads from already-loaded
    /// values (never the DB). Pure; safe to call from a menu builder.
    func games(for ids: Set<Int64>) -> [GameSummary] {
        games.filter { ids.contains($0.id) }
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

    /// Bulk "Change Copy Format ▸ Physical / Digital / ROM" (PLAN §13.3). Applies to the
    /// selection's single-copy games; several-copy games are skipped (banner). One undo step.
    func changeCopyFormat(_ ids: Set<Int64>? = nil, to format: ProductFormat) {
        let targets = ids ?? selectedGameIDs
        guard !targets.isEmpty else { return }
        Task { await actions?.changeCopyFormat(ids: targets, to: format) }
    }

    /// Whether the "Change Copy Format" commands should be enabled: a non-empty selection
    /// in a library grid destination.
    var canChangeSelectionCopyFormat: Bool {
        !selectedGameIDs.isEmpty && isLibraryGridDestination
    }

    // MARK: Commands

    func toggleInspector() { inspectorPresented.toggle() }
    func showInspector() { inspectorPresented = true; onShowInspector() }
    func requestSearchFocus() { searchFocusRequests &+= 1 }
    func requestQuickAdd() { quickAddPresented = true; onQuickAdd() }

    /// Open Quick Add prefilled with `prefill` (empty-result affordance, PLAN §8).
    func requestQuickAdd(prefill: String?) {
        quickAddPrefill = prefill?.trimmingCharacters(in: .whitespacesAndNewlines)
        requestQuickAdd()
    }

    /// The pending Quick Add prefill, consumed once by the presenting view.
    func consumeQuickAddPrefill() -> String? {
        defer { quickAddPrefill = nil }
        return (quickAddPrefill?.isEmpty == false) ? quickAddPrefill : nil
    }

    // MARK: Search keyboard flow (PLAN §8)

    /// `esc` in the search field: clear a non-empty query (return true, stays
    /// focused), else the caller unfocuses.
    @discardableResult
    func clearSearch() -> Bool {
        guard !searchText.isEmpty else { return false }
        searchText = ""
        return true
    }

    /// The first row in the current ordering (for ↩ / ↓ from the search field).
    var firstResult: GameSummary? { games.first }

    /// ↓ from the search field: move keyboard focus into the grid, selecting the
    /// first result.
    func focusGridFromSearch() {
        if let first = firstResult { selectOnly(first.id) }
        gridFocusRequests &+= 1
    }

    /// ↩ in the search field: open the inspector on the single/first result.
    func openFirstResult() {
        guard let first = firstResult else { return }
        selectOnly(first.id)
        showInspector()
    }

    /// "Search all" escape: broaden a scoped search to the whole library, keeping
    /// the query and other facets (PLAN §8).
    func searchAllScope() {
        guard selection != .all else { return }
        select(.all)
    }

    /// Open the "Link to IGDB…" / "Change IGDB Match…" sheet for one game (PLAN §5.1).
    /// Called from the inspector, grid context menu and Game menu — never a body/menu
    /// *builder* (a Button action).
    func requestLinkToIGDB(gameID: Int64) { onLinkToIGDB(gameID) }

    /// Open the "Expand Bundle into Games…" confirm flow for one game (PLAN §5.1 repair
    /// path). The presenter verifies against IGDB on demand and no-ops when it is not a
    /// bundle. Called from the inspector / grid context menu — never a menu *builder*.
    func requestExpandBundle(gameID: Int64) { onExpandBundle(gameID) }

    /// After a mutation that may drop `ids` from the current scope (e.g. a link that
    /// leaves the "Unlinked" list, or a merge that deletes a game), plan a sensible
    /// reselection to the vacated position — the same mechanism "Mark Played As" uses
    /// for Backlog. A no-op when the games stay in scope.
    func planReselectionAfterMutation(_ ids: Set<Int64>) { planReselection(removing: ids) }

    /// Inspector "Refresh metadata" — re-fetch everything for one game (PLAN §6.1).
    func refreshMetadata(gameID: Int64) { onRefreshMetadata(gameID) }

    /// Manual cover from a dropped/chosen image file (PLAN §5.2 point 4).
    func importCover(gameID: Int64, from url: URL) { onImportCover(gameID, url) }

    /// Remove a hand-picked cover and let enrichment fetch one again (PLAN §5.2).
    func removeCustomCover(gameID: Int64) { onRemoveCover(gameID) }

    /// True when the cover loader can browse candidates (live/sample services
    /// present) — gates the "Choose Cover…" entry points.
    var canChooseCover: Bool { coverLoader is any ChooseCoverProviding }

    /// Present the "Choose Cover…" sheet for one game (inspector button / grid
    /// context menu, PLAN §5.2 step 4). No-op when the loader can't browse or the
    /// game isn't loaded. Never called from a view `body`.
    func requestChooseCover(gameID: Int64) {
        guard let backend = coverLoader as? (any ChooseCoverProviding),
              let game = games.first(where: { $0.id == gameID }) else { return }
        let model = ChooseCoverModel(gameID: gameID, title: game.title,
                                     currentCoverFile: game.coverFile, backend: backend)
        model.onFinished = { [weak self] in self?.chooseCoverRequest = nil }
        chooseCoverRequest = model
    }

    /// Open the compilation editor for a product (PLAN §5.1).
    func editCompilation(productID: Int64) { onEditCompilation(productID) }

    /// "Group as compilation…" from the current multi-selection (PLAN §8).
    func groupSelectionAsCompilation() { onGroupAsCompilation(selectedGameIDs) }

    /// "Show compilation" — select every member of a compilation product (PLAN §8).
    func showCompilation(productID: Int64) {
        Task { [dataSource] in
            let ids = await dataSource.compilationMemberIDs(productID: productID)
            guard !ids.isEmpty else { return }
            self.selectedGameIDs = Set(ids)
            self.selectionAnchor = ids.first
        }
    }

    /// Load a fresh library-stats snapshot for the sidebar popover (PLAN §6.4).
    func libraryStats() async -> LibraryStats { await dataSource.libraryStats() }

    // MARK: Empty states
    var isEmptyLibrary: Bool { counts.all == 0 }
    var isEmptyFilterResult: Bool { games.isEmpty && !isEmptyLibrary }

    // MARK: Non-blocking feedback

    /// Show a transient banner (auto-dismisses). Errors are surfaced here rather
    /// than swallowed (PLAN §8).
    func showBanner(_ message: String, kind: LibraryBanner.Kind = .info) {
        banner = LibraryBanner(message: message, kind: kind)
        bannerAction = nil
        bannerSecondaryAction = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 4))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    /// Show a **persistent** banner with an action button (e.g. Batocera "Review…",
    /// PLAN §15). It does not auto-dismiss; the action or the ✕ clears it.
    func showBanner(_ message: String, kind: LibraryBanner.Kind = .info,
                    actionTitle: String, action: @escaping @MainActor () -> Void,
                    secondaryActionTitle: String? = nil,
                    secondaryAction: (@MainActor () -> Void)? = nil) {
        bannerDismissTask?.cancel()
        bannerAction = action
        bannerSecondaryAction = secondaryAction
        banner = LibraryBanner(message: message, kind: kind, actionTitle: actionTitle,
                               secondaryActionTitle: secondaryActionTitle)
    }

    /// Run the current banner's action (if any) and dismiss it.
    func performBannerAction() {
        let action = bannerAction
        dismissBanner()
        action?()
    }

    /// Run the current banner's **second** action (if any) and dismiss it.
    func performBannerSecondaryAction() {
        let action = bannerSecondaryAction
        dismissBanner()
        action?()
    }

    func dismissBanner() {
        bannerDismissTask?.cancel()
        bannerAction = nil
        bannerSecondaryAction = nil
        banner = nil
    }
}
