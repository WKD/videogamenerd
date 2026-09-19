import Foundation
import Observation

// MARK: - Seams (small protocols so the model is unit-testable with fakes)

/// Remote catalogue autocomplete (IGDB). The live implementation wraps
/// ``IGDBAutocomplete`` + ``IGDBClient`` (PLAN §5.1/§6.1); tests inject a fake.
protocol CatalogSearching: Sendable {
    /// Autocomplete `text`. Throws `IGDBError.missingCredentials` when IGDB is not
    /// configured (the model then shows local + manual rows only).
    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult]
    /// Member games of a bundle result (forward relation + reverse fallback).
    func bundleMembers(bundleIGDBID: Int64) async throws -> [IGDBSearchResult]
    /// Whether IGDB credentials are present (drives the offline hint up front).
    func hasCredentials() async -> Bool
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
    var igdbID: Int64?
    var source: Source
    /// The matching library game, or nil when this row is not in the library yet.
    var libraryMatch: QuickAddLibraryMatch?

    var isInLibrary: Bool { libraryMatch != nil }

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
            let matches = await self.library.localMatches(text)
            self.applyLocal(matches, generation: generation)
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
                let hits = await catalogCache.searchTitles(text, limit: 12)
                self.applyCached(hits, generation: generation)
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
        } else {
            await addSingle(result, openInspector: openInspector)
        }
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
        let members = (try? await catalog.bundleMembers(bundleIGDBID: igdbID)) ?? []
        bundleInFlightID = nil
        if Task.isCancelled { return }

        // Empty member list → fall back to a single game and say so (PLAN §6.1).
        guard !members.isEmpty else {
            let draft = GameDraft(
                title: result.title, igdbID: igdbID, year: result.year,
                altTitles: result.alternativeNames, platformIDs: [platform],
                owned: flags.owned, played: flags.played,
                tierID: tierID(for: tierLetter), format: flags.format, source: .manual
            )
            do {
                let outcome = try await library.add(draft)
                onLibraryChanged()
                finishAdd(
                    outcome.gameID,
                    message: "Added “\(result.title)” as a single game — IGDB had no member list.",
                    openInspector: openInspector
                )
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
            finishAdd(
                outcomes.first?.gameID,
                message: "Added “\(result.title)” as a compilation (\(outcomes.count) games).",
                openInspector: openInspector
            )
        } catch {
            confirmation = QuickAddConfirmation(message: "Couldn't add “\(result.title)”.", gameID: nil, isError: true)
        }
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
