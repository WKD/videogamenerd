import Foundation
import Observation

/// One search result in the link sheet: an IGDB game plus whether a library game
/// already carries its id (the "already in your library" marker).
struct IGDBLinkResult: Identifiable, Sendable, Equatable {
    let result: IGDBSearchResult
    /// The library game already linked to this IGDB id, if any.
    let existingGameID: Int64?
    /// That existing game IS the one we are (re)linking — so it is the current match,
    /// not a merge target.
    let isCurrentGame: Bool

    var id: Int64 { result.id }
    /// Shown as "already in your library" (a *different* game holds this id → merge).
    var alreadyInLibrary: Bool { existingGameID != nil && !isCurrentGame }
    /// A bundle/pack — disabled as a target (a single game can't stand in for a bundle).
    var isBundle: Bool { result.isBundle }
    /// Selectable as a link target (bundles are not).
    var isChoosable: Bool { !isBundle }
}

/// What the owner chose in the link sheet, handed to the action layer to perform the
/// LINK / RE-LINK / MERGE (PLAN §5.1).
struct IGDBLinkChoice: Sendable, Equatable {
    var igdbID: Int64
    var title: String
    var year: Int?
    /// Non-nil when a *different* library game already holds this IGDB id → merge into it.
    var existingGameID: Int64?
    var isBundle: Bool
}

/// The link / change-match search sheet's model (PLAN §5.1). `@MainActor @Observable`;
/// reuses Quick Add's debounced, cancellable, stale-dropping search against the shared
/// `CatalogSearching` seam (same name-prefix / alt-name / typed-year fallbacks). Built
/// with a fake searcher in tests — no network.
@MainActor
@Observable
final class IGDBLinkModel {
    enum Phase: Equatable { case idle, searching, results, empty, error, notConfigured }

    let gameID: Int64
    let currentTitle: String
    let platformSlugs: [String]
    let year: Int?
    /// The game already carries an IGDB id (→ "Change IGDB Match" rather than "Link…").
    let isLinked: Bool

    /// The search field, prefilled with the cleaned title (the owner edits it freely).
    var query: String {
        didSet { if query != oldValue { onQueryChanged() } }
    }
    /// "Only <platform>" — constrain the search to the game's platform(s). On by default
    /// when the game has a platform; off searches every platform.
    var onlyThisPlatform: Bool {
        didSet { if onlyThisPlatform != oldValue { onQueryChanged() } }
    }

    private(set) var results: [IGDBLinkResult] = []
    private(set) var phase: Phase = .idle
    var selectedIndex: Int = 0

    // Seams
    private let searcher: any CatalogSearching
    private let platformIGDBIDs: [Int]
    private let libraryIndex: [Int64: Int64]
    private let limit: Int
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    private var searchTask: Task<Void, Never>?
    private var generation = 0

    var onChoose: (IGDBLinkChoice) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(
        gameID: Int64,
        currentTitle: String,
        platformSlugs: [String],
        year: Int?,
        isLinked: Bool,
        prefill: String,
        searcher: any CatalogSearching,
        platformIGDBIDs: [Int] = [],
        libraryIndex: [Int64: Int64] = [:],
        limit: Int = 12,
        debounce: Duration = .milliseconds(150),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.gameID = gameID
        self.currentTitle = currentTitle
        self.platformSlugs = platformSlugs
        self.year = year
        self.isLinked = isLinked
        self.query = prefill
        self.onlyThisPlatform = !platformSlugs.isEmpty && !platformIGDBIDs.isEmpty
        self.searcher = searcher
        self.platformIGDBIDs = platformIGDBIDs
        self.libraryIndex = libraryIndex
        self.limit = limit
        self.debounce = debounce
        self.sleep = sleep
    }

    var sheetTitle: String { isLinked ? "Change IGDB Match" : "Link to IGDB" }
    /// Whether the "Only <platform>" toggle is meaningful (the game has a mapped platform).
    var canConstrainPlatform: Bool { !platformIGDBIDs.isEmpty }
    var platformToggleLabel: String {
        guard let slug = platformSlugs.first else { return "Only this platform" }
        return "Only \(PlatformLabels.short(slug))"
    }

    /// Kick the first search (call from `.task`, once). Idempotent-ish: safe to call
    /// again — it just re-runs the current query.
    func start() { onQueryChanged() }

    private func onQueryChanged() {
        searchTask?.cancel()
        generation &+= 1
        let generation = generation
        selectedIndex = 0
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else {
            results = []
            phase = .idle
            return
        }
        phase = .searching
        let platforms: [Int]? = (onlyThisPlatform && !platformIGDBIDs.isEmpty) ? platformIGDBIDs : nil
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(self.debounce)
            if Task.isCancelled || generation != self.generation { return }
            await self.runSearch(text: query, platforms: platforms, generation: generation)
        }
    }

    private func runSearch(text: String, platforms: [Int]?, generation: Int) async {
        do {
            let raw = try await searcher.search(text, platformIGDBIDs: platforms, limit: limit)
            apply(raw, generation: generation)
        } catch is CancellationError {
            // superseded — ignore
        } catch IGDBError.missingCredentials {
            guard generation == self.generation else { return }
            results = []; phase = .notConfigured
        } catch {
            guard generation == self.generation else { return }
            results = []; phase = .error
        }
    }

    /// Apply results (stale-drop by generation), tagging library membership.
    func apply(_ raw: [IGDBSearchResult], generation: Int) {
        guard generation == self.generation else { return }
        results = raw.map { r in
            let existing = libraryIndex[r.id]
            return IGDBLinkResult(result: r, existingGameID: existing, isCurrentGame: existing == gameID)
        }
        selectedIndex = 0
        phase = results.isEmpty ? .empty : .results
    }

    // MARK: Keyboard

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    func chooseSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        choose(results[selectedIndex])
    }

    /// Choose a result as the (re)link / merge target. Bundles are refused. Choosing the
    /// game's own current link is a no-op (cancels the sheet).
    func choose(_ row: IGDBLinkResult) {
        guard row.isChoosable else { return }
        if row.isCurrentGame { onCancel(); return }
        onChoose(IGDBLinkChoice(
            igdbID: row.result.id,
            title: row.result.name,
            year: row.result.releaseYear,
            existingGameID: row.alreadyInLibrary ? row.existingGameID : nil,
            isBundle: row.isBundle))
    }

    func cancel() { searchTask?.cancel(); onCancel() }
}
