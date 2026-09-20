import Foundation
import Observation

// MARK: - Seams (small protocols so the model is unit-testable with fakes)

/// Remote catalogue autocomplete (IGDB). The live implementation wraps
/// ``IGDBAutocomplete`` + ``IGDBClient`` (PLAN §5.1/§6.1); tests inject a fake.
protocol CatalogSearching: Sendable {
    /// Autocomplete `text`. Throws `IGDBError.missingCredentials` when IGDB is not
    /// configured (the model then shows local + manual rows only).
    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult]
    /// Member games of a bundle result after the one member policy (PLAN §5.1): non-standalone
    /// content dropped and ports folded onto their parent, with the "left out" notes.
    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult
    /// The parent game a **port** result links to (PLAN §5.1 D4): given the parent id (from
    /// the result's `version_parent` / `parent_game`), the parent's title/year **when it is
    /// itself a standalone game**, else nil. Default: nil (fakes / offline).
    func portParent(parentID: Int64) async -> PortParentInfo?
    /// Whether IGDB credentials are present (drives the offline hint up front).
    func hasCredentials() async -> Bool
}

extension CatalogSearching {
    func portParent(parentID: Int64) async -> PortParentInfo? { nil }
}

/// The original game a port links to (PLAN §5.1 D4 — "a port is the same game").
struct PortParentInfo: Sendable, Equatable, Identifiable {
    var id: Int64
    var name: String
    var year: Int?
    /// "Super Mario Galaxy (2007)" — for the confirm line.
    var display: String { year.map { "\(name) (\($0))" } ?? name }
}

/// Local-library search + the writes Quick Add performs. The live implementation
/// wraps ``LibraryStore``; tests inject a fake.
protocol LibraryAdding: Sendable {
    /// Existing library games whose title matches `text` (the "already in library"
    /// marker and the local-instant rows).
    func localMatches(_ text: String) async -> [QuickAddLibraryMatch]
    func add(_ draft: GameDraft) async throws -> AddOutcome
    func addCompilation(
        product: ProductDraft, members: [CompilationMemberDraft]
    ) async throws -> (productID: Int64, members: [AddOutcome])
}

// MARK: - Value types

/// The sticky flags Quick Add carries between adds and across launches (PLAN §6.1:
/// "sticky from last add").
struct QuickAddFlags: Sendable, Equatable {
    var owned: Bool = true
    var played: Bool = false
    var format: ProductFormat = .physical
}

/// Persistence for the sticky flags (injected so a test can use an in-memory store
/// and assert the ROM format survives across model instances).
protocol QuickAddPreferenceStoring: Sendable {
    func loadFlags() -> QuickAddFlags
    func saveFlags(_ flags: QuickAddFlags)
}

/// A library game that matched the query — enough to mark a catalogue row as owned
/// and to render a local-only row.
struct QuickAddLibraryMatch: Sendable, Equatable, Identifiable {
    var gameID: Int64
    var title: String
    var normalizedTitle: String
    var year: Int?
    var platformIDs: [String]
    var owned: Bool
    var played: Bool
    var hasROM: Bool
    var coverFile: String?

    var id: Int64 { gameID }

    init(from summary: GameSummary) {
        gameID = summary.id
        title = summary.title
        normalizedTitle = TitleNormalizer.normalize(summary.title, level: .articleless)
        year = summary.year
        platformIDs = summary.platformIDs
        owned = summary.owned
        played = summary.played
        hasROM = summary.hasROM
        coverFile = summary.coverFile
    }
}

/// One row in the palette (a catalogue hit, or a library game with no catalogue
/// counterpart).
struct QuickAddResult: Identifiable, Sendable, Equatable {
    enum Source: Sendable, Equatable { case catalog, local }

    var id: String
    var title: String
    var year: Int?
    var platformSlugs: [String]
    /// IGDB cover image id → the small thumbnail URL (catalogue rows).
    var coverImageID: String?
    /// A stored local cover file (local-only rows).
    var coverFile: String?
    var alternativeNames: [String]
    var genres: [String]
    var isBundle: Bool
    /// The IGDB `game_type` for a catalogue row (`.mainGame` for a local-only row), so the
    /// row can mark a non-standalone / port result (PLAN §5.1 D4).
    var gameType: IGDBGameType
    /// A port result's parent id (`version_parent` / `parent_game`), for the "link to the
    /// original" flow (PLAN §5.1 D4); nil when not a port / unknown.
    var foldParentID: Int64?
    var igdbID: Int64?
    var source: Source
    /// The matching library game, or nil when this row is not in the library yet.
    var libraryMatch: QuickAddLibraryMatch?

    var isInLibrary: Bool { libraryMatch != nil }

    /// A short label when this catalogue result is not a plain main game and not a bundle —
    /// "Expansion", "DLC", "Port"… (PLAN §5.1 D4). A boxed expansion is a legitimate pick, so
    /// the row stays selectable; the label just says what it is. nil for local / main / bundle.
    var typeLabel: String? {
        guard source == .catalog, !isBundle else { return nil }
        return GameTypePolicy.label(for: gameType)
    }

    init(catalog r: IGDBSearchResult, libraryMatch: QuickAddLibraryMatch?) {
        id = "igdb:\(r.id)"
        title = r.name
        year = r.releaseYear
        platformSlugs = r.platformSlugs
        coverImageID = r.coverImageID
        coverFile = libraryMatch?.coverFile
        alternativeNames = r.alternativeNames
        genres = r.genres
        isBundle = r.isBundle
        gameType = r.gameType
        foldParentID = r.foldParentID
        igdbID = r.id
        source = .catalog
        self.libraryMatch = libraryMatch
    }

    init(local m: QuickAddLibraryMatch) {
        id = "local:\(m.gameID)"
        title = m.title
        year = m.year
        platformSlugs = m.platformIDs
        coverImageID = nil
        coverFile = m.coverFile
        alternativeNames = []
        genres = []
        isBundle = false
        gameType = .mainGame
        foldParentID = nil
        igdbID = nil
        source = .local
        libraryMatch = m
    }
}

/// The brief inline confirmation shown after an add (PLAN §6.1).
struct QuickAddConfirmation: Sendable, Equatable {
    var message: String
    var gameID: Int64?
    var isError: Bool = false
}

/// The pending "this is a port — add the original?" confirm (PLAN §5.1 D4).
struct PortConfirmState: Sendable, Equatable {
    var result: QuickAddResult
    var parent: PortParentInfo
    var openInspector: Bool
}

// MARK: - Model

/// All Quick Add logic (PLAN §6.1) behind the small protocols above, so the view is
/// a thin shell and the flow is unit-testable with fakes. `@MainActor @Observable`.
@MainActor
@Observable
final class QuickAddModel {
    // Seams
    private let catalog: any CatalogSearching
    /// Instant/offline catalogue-cache title search (PLAN §6.1). Optional — nil
    /// disables the cached rows (tests / no services).
    private let catalogCache: (any CatalogTitleSearching)?
    private let library: any LibraryAdding
    private let preferences: any QuickAddPreferenceStoring
    private let allPlatforms: [PlatformInfo]
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let platformGeneration: @Sendable (String) -> Int?

    // Callbacks to the app
    var onOpenInspector: (Int64) -> Void = { _ in }
    var onLibraryChanged: () -> Void = {}
    var onRequestClose: () -> Void = {}

    // Query + results
    var query: String = "" {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    private(set) var results: [QuickAddResult] = []
    private(set) var selectedIndex: Int = 0
    private(set) var isSearchingRemote = false
    private(set) var credentialsAvailable = true
    private(set) var confirmation: QuickAddConfirmation?
    /// The result id whose bundle members are being fetched (row spinner).
    private(set) var bundleInFlightID: String?
    /// Set while the owner is confirming a **port** commit (PLAN §5.1 D4): add the original
    /// game, or the port entry instead. Nil the rest of the time.
    private(set) var portConfirm: PortConfirmState?

    // Sticky + per-entry state
    private(set) var flags: QuickAddFlags
    private(set) var tierLetter: String?
    /// The platform chosen with Tab for the current result (nil = the default).
    private(set) var platformOverride: String?

    // Context (set on show)
    private(set) var tiers: [TierInfo] = TierInfo.defaultTiers
    private var sidebarPlatform: String?
    private var ownedPlatforms: Set<String> = []

    // Internal search state
    private var catalogResults: [IGDBSearchResult] = []
    /// Instant catalogue-cache hits shown before the debounced live results.
    private var cachedResults: [IGDBSearchResult] = []
    /// True once a live IGDB response (with credentials) has arrived for the
    /// current query — then the live results become the source of truth and
    /// replace the cached rows for shared ids (PLAN §6.1).
    private var liveArrived = false
    private var localMatches: [QuickAddLibraryMatch] = []
    /// Bumped on every query change; `applyRemote`/`applyLocal` drop a response
    /// carrying an older generation (stale-drop). `internal` read for tests.
    private(set) var searchGeneration = 0
    private var localTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    /// Set by `commit(keepResults:)`, consumed by `finishAdd`.
    private var keepResultsOnFinish = false

    init(
        catalog: any CatalogSearching,
        catalogCache: (any CatalogTitleSearching)? = nil,
        library: any LibraryAdding,
        preferences: any QuickAddPreferenceStoring = UserDefaultsQuickAddPreferences(),
        platforms: [PlatformInfo] = PlatformLabels.all,
        tiers: [TierInfo] = TierInfo.defaultTiers,
        debounce: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        platformGeneration: @escaping @Sendable (String) -> Int? = { PlatformLabels.info($0)?.generation }
    ) {
        self.catalog = catalog
        self.catalogCache = catalogCache
        self.library = library
        self.preferences = preferences
        self.allPlatforms = platforms
        self.tiers = tiers
        self.debounce = debounce
        self.sleep = sleep
        self.platformGeneration = platformGeneration
        self.flags = preferences.loadFlags()
    }

    // MARK: - Show / reset

    /// Prime the palette for a fresh presentation. Keeps the sticky flags; clears
    /// the transient query/results/tier.
    func prepare(sidebarPlatform: String?, ownedPlatforms: Set<String>, tiers: [TierInfo]) {
        self.sidebarPlatform = sidebarPlatform
        self.ownedPlatforms = ownedPlatforms
        if !tiers.isEmpty { self.tiers = tiers }
        reset()
        Task { credentialsAvailable = await catalog.hasCredentials() }
    }

    private func reset() {
        localTask?.cancel(); cacheTask?.cancel(); remoteTask?.cancel(); commitTask?.cancel()
        searchGeneration &+= 1
        query = ""
        results = []
        catalogResults = []
        cachedResults = []
        liveArrived = false
        localMatches = []
        selectedIndex = 0
        platformOverride = nil
        tierLetter = nil
        confirmation = nil
        bundleInFlightID = nil
        portConfirm = nil
        isSearchingRemote = false
    }

    // MARK: - Search (debounce + cancellation + stale-drop)

    private func onQueryChanged() {
        confirmation = nil
        searchGeneration &+= 1
        let generation = searchGeneration
        let text = query
        selectedIndex = 0
        platformOverride = nil
        liveArrived = false

        // Local library: instant (PLAN §6.1 "local library … instantly").
        localTask?.cancel()
        localTask = Task { [weak self] in
            guard let self else { return }
            // A typed year ("super mario bros 1985") is not part of any title: search
            // on the text without it, then put the entries of that year first.
            let split = IGDBAutocomplete.splitYear(text)
            let matches = await self.library.localMatches(split.text)
            self.applyLocal(Self.yearFirst(matches, year: split.year, yearOf: \.year), generation: generation)
        }

        // Remote: debounced, previous cancelled, ≥ 3 chars.
        remoteTask?.cancel()
        cacheTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            catalogResults = []
            cachedResults = []
            isSearchingRemote = false
            rebuildResults()
            return
        }

        // Catalogue cache: instant, offline (PLAN §6.1 "catalog cache instantly").
        // Shown before the debounced live results; live replaces it per id later.
        if let catalogCache {
            cacheTask = Task { [weak self] in
                guard let self else { return }
                let split = IGDBAutocomplete.splitYear(text)
                let hits = await catalogCache.searchTitles(split.text, limit: split.year == nil ? 12 : 40)
                let ordered = Self.yearFirst(hits, year: split.year, yearOf: \.releaseYear)
                self.applyCached(Array(ordered.prefix(12)), generation: generation)
            }
        }

        isSearchingRemote = true
        remoteTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.debounce)
            if Task.isCancelled || generation != self.searchGeneration { return }
            await self.runRemote(text: text, generation: generation)
        }
    }

    private func runRemote(text: String, generation: Int) async {
        do {
            let results = try await catalog.search(text, platformIGDBIDs: nil, limit: 12)
            applyRemote(results, generation: generation, credentials: true)
        } catch is CancellationError {
            // superseded — ignore
        } catch IGDBError.missingCredentials {
            applyRemote([], generation: generation, credentials: false)
        } catch {
            // Offline / transient: keep whatever local rows we have; credentials
            // exist, so don't flip to the "add credentials" hint.
            guard generation == searchGeneration else { return }
            isSearchingRemote = false
            rebuildResults()
        }
    }

    /// Guarded apply of a remote response — a stale generation never overwrites a
    /// newer query's results (belt-and-suspenders alongside task cancellation).
    func applyRemote(_ results: [IGDBSearchResult], generation: Int, credentials: Bool) {
        guard generation == searchGeneration else { return }
        catalogResults = results
        // A live response (with credentials) arrived → it now owns the catalog rows.
        // Without credentials (offline/not configured) the cached rows stay.
        liveArrived = credentials
        credentialsAvailable = credentials
        isSearchingRemote = false
        rebuildResults()
    }

    /// Guarded apply of instant catalogue-cache hits.
    func applyCached(_ results: [IGDBSearchResult], generation: Int) {
        guard generation == searchGeneration else { return }
        cachedResults = results
        rebuildResults()
    }

    /// Stable partition: entries released in `year` first. When at least one entry
    /// matches, the others are dropped (the year was typed to disambiguate); when none
    /// does, the list is returned unchanged (a wrong year must not hide everything).
    static func yearFirst<T>(_ items: [T], year: Int?, yearOf: (T) -> Int?) -> [T] {
        guard let year else { return items }
        let hits = items.filter { yearOf($0) == year }
        return hits.isEmpty ? items : hits
    }

    /// Guarded apply of local matches.
    func applyLocal(_ matches: [QuickAddLibraryMatch], generation: Int) {
        guard generation == searchGeneration else { return }
        localMatches = matches
        rebuildResults()
    }

    private func rebuildResults() {
        let catalog = Self.mergeCatalog(
            cached: cachedResults, live: catalogResults, liveArrived: liveArrived, limit: 12)
        results = Self.buildResults(catalog: catalog, local: localMatches)
        if selectedIndex >= results.count { selectedIndex = max(0, results.count - 1) }
        if let sel = selectedResult, let ov = platformOverride, !sel.platformSlugs.contains(ov) {
            platformOverride = nil
        }
    }

    /// Merge instant cached hits with the (later) live hits (pure, unit-tested).
    /// Before the live response arrives, the cached rows are shown as-is. Once it
    /// arrives, the live results are authoritative and lead — replacing a cached
    /// row for the same id (no duplicate, no jump) — and any cached-only ids are
    /// kept appended after, capped to `limit`.
    static func mergeCatalog(
        cached: [IGDBSearchResult], live: [IGDBSearchResult], liveArrived: Bool, limit: Int
    ) -> [IGDBSearchResult] {
        guard liveArrived else { return Array(cached.prefix(limit)) }
        var seen = Set(live.map(\.id))
        var out = live
        for c in cached where !seen.contains(c.id) {
            seen.insert(c.id)
            out.append(c)
        }
        return Array(out.prefix(limit))
    }

    /// Merge catalogue hits with local matches (pure, unit-tested). Catalogue rows
    /// first (richer data), each marked in-library when a local game shares its
    /// normalised title; then any remaining library games as local-only rows.
    static func buildResults(
        catalog: [IGDBSearchResult], local: [QuickAddLibraryMatch]
    ) -> [QuickAddResult] {
        var out: [QuickAddResult] = []
        var usedLocal = Set<Int64>()
        var localByKey: [String: [QuickAddLibraryMatch]] = [:]
        for m in local { localByKey[m.normalizedTitle, default: []].append(m) }

        for r in catalog {
            let key = TitleNormalizer.normalize(r.name, level: .articleless)
            let match = localByKey[key]?.first { !usedLocal.contains($0.gameID) }
            if let match { usedLocal.insert(match.gameID) }
            out.append(QuickAddResult(catalog: r, libraryMatch: match))
        }
        for m in local where !usedLocal.contains(m.gameID) {
            out.append(QuickAddResult(local: m))
        }
        return out
    }

    // MARK: - Selection & platform

    var selectedResult: QuickAddResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
        platformOverride = nil
    }

    /// Select a specific row (mouse click).
    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        platformOverride = nil
    }

    /// The platform an add would use: the Tab override if still valid, else the
    /// default (PLAN §6.1 default-platform rule), else the sidebar platform.
    var effectivePlatform: String? {
        guard let sel = selectedResult else { return sidebarPlatform }
        if let ov = platformOverride, sel.platformSlugs.contains(ov) { return ov }
        return Self.defaultPlatform(
            options: sel.platformSlugs, sidebar: sidebarPlatform,
            owned: ownedPlatforms, generation: platformGeneration
        ) ?? sidebarPlatform
    }

    /// Tab / ⇧Tab cycle the platform among the result's platforms.
    func cyclePlatform(by delta: Int) {
        guard let sel = selectedResult, !sel.platformSlugs.isEmpty else { return }
        let options = sel.platformSlugs
        let current = effectivePlatform.flatMap { options.firstIndex(of: $0) } ?? 0
        let count = options.count
        let next = ((current + delta) % count + count) % count
        platformOverride = options[next]
    }

    /// PLAN §6.1 default platform: the sidebar's current platform if the game is on
    /// it, else the newest platform the user already owns games on, else the newest.
    static func defaultPlatform(
        options: [String], sidebar: String?, owned: Set<String>,
        generation: @Sendable (String) -> Int?
    ) -> String? {
        guard !options.isEmpty else { return nil }
        if let sidebar, options.contains(sidebar) { return sidebar }
        let ownedOptions = options.filter { owned.contains($0) }
        if let best = newest(ownedOptions, generation) { return best }
        return newest(options, generation)
    }

    private static func newest(_ slugs: [String], _ generation: @Sendable (String) -> Int?) -> String? {
        guard !slugs.isEmpty else { return nil }
        return slugs.enumerated().max { a, b in
            let ga = generation(a.element) ?? Int.min
            let gb = generation(b.element) ?? Int.min
            if ga != gb { return ga < gb }
            return a.offset > b.offset          // tie → earliest listed wins
        }?.element
    }

    // MARK: - Flags (sticky) + tier (per-entry)

    func toggleOwned() { flags.owned.toggle(); persistFlags() }
    func togglePlayed() { flags.played.toggle(); persistFlags() }

    /// ⌘D cycles the owned format physical → digital → ROM (PLAN §6.1 + §7b).
    func cycleFormat() {
        switch flags.format {
        case .physical: flags.format = .digital
        case .digital: flags.format = .rom
        case .rom: flags.format = .physical
        }
        persistFlags()
    }

    /// Pick the copy format directly (footer picker, ⌘1 / ⌘2 / ⌘3). Choosing a format
    /// means "I own this copy", so it also switches Owned on. Sticky like the other flags.
    func setFormat(_ format: ProductFormat) {
        flags.format = format
        flags.owned = true
        persistFlags()
    }

    /// ⌃S…⌃F set the tier (implies played); ⌃0 clears it.
    func setTier(_ letter: String?) {
        tierLetter = letter
        if letter != nil, !flags.played { flags.played = true; persistFlags() }
    }

    private func persistFlags() { preferences.saveFlags(flags) }

    // MARK: - Commit (↩ / ⌘↩)

    /// Add the selected result and stay open (`openInspector == false`) or add and
    /// open the inspector on it (`openInspector == true`). Never waits on the
    /// network to *insert* (PLAN §6.1). With no results, adds the typed text
    /// manually.
    ///
    /// `keepResults` (⇧↩) adds the selected row but keeps the query and the result
    /// list, then moves the selection to the next row — for adding a whole series
    /// ("yakuza" → ⇧↩ ⇧↩ ⇧↩) without retyping. Ignored with `openInspector`.
    func commit(openInspector: Bool, keepResults: Bool = false) {
        // While the port confirm is up, ↩ means "add the original" (its default action).
        if portConfirm != nil { confirmPortOriginal(); return }
        commitTask?.cancel()
        keepResultsOnFinish = keepResults && !openInspector
        commitTask = Task { [weak self] in await self?.performCommit(openInspector: openInspector) }
    }

    private func performCommit(openInspector: Bool) async {
        guard let result = selectedResult else {
            await addManual(openInspector: openInspector)
            return
        }
        if result.isBundle {
            await addBundle(result, openInspector: openInspector)
        } else if result.gameType == .port, let parentID = result.foldParentID {
            await beginPortCommit(result, parentID: parentID, openInspector: openInspector)
        } else {
            await addSingle(result, openInspector: openInspector)
        }
    }

    // MARK: - Port commit (PLAN §5.1 D4 — "a port is the same game")

    /// The selected result is a port. Resolve its parent (one read-through `games(ids:)`);
    /// if the original is a real standalone game, pause on a confirm ("add the original" /
    /// "add the port instead"); if it doesn't resolve, add the port as chosen.
    private func beginPortCommit(_ result: QuickAddResult, parentID: Int64, openInspector: Bool) async {
        bundleInFlightID = result.id           // reuse the row spinner while resolving
        let parent = await catalog.portParent(parentID: parentID)
        bundleInFlightID = nil
        if Task.isCancelled { return }
        guard let parent else {
            await addSingle(result, openInspector: openInspector)
            return
        }
        portConfirm = PortConfirmState(result: result, parent: parent, openInspector: openInspector)
    }

    /// Add the original game (the port's parent) as a copy on the chosen platform.
    func confirmPortOriginal() {
        guard let state = portConfirm else { return }
        portConfirm = nil
        commitTask?.cancel()
        commitTask = Task { [weak self] in await self?.addResolvedPort(state) }
    }

    /// Add the port entry itself instead (the secondary action).
    func usePortEntry() {
        guard let state = portConfirm else { return }
        portConfirm = nil
        commitTask?.cancel()
        commitTask = Task { [weak self] in await self?.addSingle(state.result, openInspector: state.openInspector) }
    }

    func cancelPortConfirm() { portConfirm = nil }

    private func addResolvedPort(_ state: PortConfirmState) async {
        let platform = effectivePlatform      // from the still-selected port result
        let draft = GameDraft(
            title: state.parent.name, igdbID: state.parent.id, year: state.parent.year,
            altTitles: [], platformIDs: platform.map { [$0] } ?? [],
            owned: platform != nil && flags.owned, played: flags.played,
            tierID: tierID(for: tierLetter), format: flags.format, source: .manual)
        await add(draft, title: state.parent.name, platform: platform, openInspector: state.openInspector)
    }

    /// Explicit "Create '…' manually" row action.
    func addManualRow() {
        commitTask?.cancel()
        commitTask = Task { [weak self] in await self?.addManual(openInspector: false) }
    }

    private func addSingle(_ result: QuickAddResult, openInspector: Bool) async {
        let platform = effectivePlatform
        let tierID = tierID(for: tierLetter)
        let draft = GameDraft(
            title: result.title,
            igdbID: result.igdbID,
            year: result.year,
            altTitles: result.alternativeNames,
            platformIDs: platform.map { [$0] } ?? [],
            owned: platform != nil && flags.owned,
            played: flags.played,
            tierID: tierID,
            format: flags.format,
            source: .manual
        )
        await add(draft, title: result.title, platform: platform, openInspector: openInspector)
    }

    private func addManual(openInspector: Bool) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let manual = ManualAddModel(platforms: allPlatforms, tiers: tiers, defaultPlatform: sidebarPlatform)
        manual.title = trimmed
        manual.owned = flags.owned
        manual.format = flags.format
        manual.played = flags.played
        manual.tierLetter = tierLetter
        guard let draft = manual.makeDraft() else { return }
        await add(draft, title: trimmed, platform: manual.platformID, openInspector: openInspector)
    }

    private func add(_ draft: GameDraft, title: String, platform: String?, openInspector: Bool) async {
        do {
            let outcome = try await library.add(draft)
            onLibraryChanged()
            let message = Self.confirmationMessage(
                outcome: outcome, title: title, platform: platform, flags: flags, tier: tierLetter
            )
            finishAdd(outcome.gameID, message: message, openInspector: openInspector)
        } catch {
            confirmation = QuickAddConfirmation(message: "Couldn't add “\(title)”.", gameID: nil, isError: true)
        }
    }

    private func addBundle(_ result: QuickAddResult, openInspector: Bool) async {
        guard let igdbID = result.igdbID, let platform = effectivePlatform else {
            await addSingle(result, openInspector: openInspector)
            return
        }
        bundleInFlightID = result.id
        let expansion = (try? await catalog.bundleMembers(bundleIGDBID: igdbID)) ?? BundleMemberResult()
        bundleInFlightID = nil
        if Task.isCancelled { return }
        let members = expansion.members
        let leftOutNote = Self.leftOutSummary(expansion.leftOut)

        // Fewer than two members left → no longer worth a compilation (PLAN §5.1): a lone
        // member becomes that single game on the copy; none falls back to the bundle single.
        if members.count < 2 {
            let single = members.first
            let draft = GameDraft(
                title: single?.name ?? result.title,
                igdbID: single?.id ?? igdbID,
                year: single?.releaseYear ?? result.year,
                altTitles: single?.alternativeNames ?? result.alternativeNames,
                platformIDs: [platform],
                owned: flags.owned, played: flags.played,
                tierID: tierID(for: tierLetter), format: flags.format, source: .manual
            )
            let base = single != nil
                ? "Added “\(single!.name)” as a single game — the bundle had only one game to keep."
                : "Added “\(result.title)” as a single game — IGDB had no member list."
            do {
                let outcome = try await library.add(draft)
                onLibraryChanged()
                finishAdd(outcome.gameID, message: Self.appending(leftOutNote, to: base),
                          openInspector: openInspector)
            } catch {
                confirmation = QuickAddConfirmation(message: "Couldn't add “\(result.title)”.", gameID: nil, isError: true)
            }
            return
        }

        let product = ProductDraft(
            title: result.title, platformID: platform, format: flags.format,
            source: .manual, igdbID: igdbID
        )
        let memberDrafts = members.enumerated().map { index, m in
            CompilationMemberDraft(
                title: m.name, igdbID: m.id, year: m.releaseYear,
                altTitles: m.alternativeNames, played: flags.played, position: index
            )
        }
        do {
            let (_, outcomes) = try await library.addCompilation(product: product, members: memberDrafts)
            onLibraryChanged()
            let base = "Added “\(result.title)” as a compilation (\(outcomes.count) games)."
            finishAdd(outcomes.first?.gameID, message: Self.appending(leftOutNote, to: base),
                      openInspector: openInspector)
        } catch {
            confirmation = QuickAddConfirmation(message: "Couldn't add “\(result.title)”.", gameID: nil, isError: true)
        }
    }

    /// A one-line "Left out: …" summary of what the member policy dropped / folded, or nil
    /// (PLAN §5.1). Bounded — at most three entries are spelled out, the rest collapse to "+n".
    static func leftOutSummary(_ leftOut: [BundleLeftOut]) -> String? {
        guard !leftOut.isEmpty else { return nil }
        let shown = leftOut.prefix(3).map(\.displayText)
        let extra = leftOut.count - shown.count
        let tail = extra > 0 ? " +\(extra) more" : ""
        return "Left out: " + shown.joined(separator: ", ") + tail
    }

    private static func appending(_ note: String?, to base: String) -> String {
        note.map { "\(base) \($0)" } ?? base
    }

    /// Common post-add: ⌘↩ opens the inspector and closes; ↩ stays open with the
    /// field cleared, focus kept, and the inline confirmation shown.
    private func finishAdd(_ gameID: Int64?, message: String, openInspector: Bool) {
        if openInspector, let gameID {
            onOpenInspector(gameID)
            onRequestClose()
            return
        }
        if keepResultsOnFinish, !results.isEmpty {
            keepResultsOnFinish = false
            tierLetter = nil      // tier is per-entry
            platformOverride = nil
            confirmation = QuickAddConfirmation(message: message, gameID: gameID)
            // Re-read the library so the row just added shows as "in library", then
            // step to the next row.
            let generation = searchGeneration, text = query, next = selectedIndex + 1
            localTask?.cancel()
            localTask = Task { [weak self] in
                guard let self else { return }
                let matches = await self.library.localMatches(text)
                self.applyLocal(matches, generation: generation)
                if generation == self.searchGeneration, self.results.indices.contains(next) {
                    self.selectedIndex = next
                }
            }
            return
        }
        keepResultsOnFinish = false
        query = ""            // clears results + confirmation via didSet…
        tierLetter = nil      // tier is per-entry
        confirmation = QuickAddConfirmation(message: message, gameID: gameID)   // …then re-shown
    }

    private func tierID(for letter: String?) -> Int64? {
        letter.flatMap { l in tiers.first { $0.letter == l }?.id }
    }

    /// PLAN §6.1 duplicate handling straight from `AddOutcome`.
    static func confirmationMessage(
        outcome: AddOutcome, title: String, platform: String?, flags: QuickAddFlags, tier: String?
    ) -> String {
        let plat = platform.map(PlatformLabels.short)
        switch outcome {
        case .created:
            var bits: [String] = []
            if flags.owned, platform != nil { bits.append("owned, \(flags.format.label.lowercased())") }
            if flags.played || tier != nil { bits.append("played") }
            if let tier { bits.append("tier \(tier)") }
            let suffix = bits.isEmpty ? "" : " · " + bits.joined(separator: " · ")
            let where_ = plat.map { " · \($0)" } ?? ""
            return "Added \(title)\(where_)\(suffix)"
        case .addedCopy:
            let where_ = plat.map { " a \($0) copy" } ?? " a copy"
            return "Added\(where_) of \(title)"
        case .alreadyPresent:
            return "“\(title)” is already in your library"
        }
    }

    // MARK: - Escape

    /// First `esc` clears a non-empty field (returns true, stays open); a second on
    /// an empty field returns false so the caller closes (PLAN §6.1).
    func handleEscape() -> Bool {
        if portConfirm != nil { portConfirm = nil; return true }   // back out of the port confirm
        if !query.isEmpty { query = ""; return true }
        return false
    }

    // MARK: - Manual row affordance

    var manualRowTitle: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Create manually…" : "Create “\(trimmed)” manually"
    }

    var canAddManual: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
