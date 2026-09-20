import AppKit
import SwiftUI

// App-level hookup for the HLTB time-estimate fallback (PLAN §5.3): a presenter the
// container builds once, a view modifier that hosts the bulk sheet + the single-game
// picker, and the Game-menu command. Mirrors `GOGImportHookup` so the hot root files
// change by one line each. Live mode injects the real `HLTBClient`; every other mode
// gets the inert, no-network search.

/// Owns the presentation state of the HLTB fetch flow (PLAN §5.3): the bulk sheet, the
/// single-game picker, the confident-fill Undo banner. One per window/container.
@MainActor
@Observable
final class HLTBFetchPresenter {
    private let store: LibraryStore
    private let makeSearch: @Sendable () -> any HLTBSearching
    /// The focused library view model — for selection scope, banners and Undo.
    weak var library: LibraryViewModel?

    /// Non-nil while the bulk sheet is up.
    var bulk: HLTBBulkFetchModel?
    /// Non-nil while the single-game picker sheet is up.
    var picker: HLTBPickerRequest?
    private(set) var isFetchingOne = false

    /// The game ids the owner dismissed as "Estimate Looks Right" (PLAN §5.3). Cached
    /// here so the inspector's ⚠︎ updates immediately on a toggle; the grid / shelves read
    /// `app_state` directly in SQL. Loaded once, then kept in sync on each toggle.
    private(set) var dismissedEstimateIDs: Set<Int64> = []

    init(store: LibraryStore, makeSearch: @escaping @Sendable () -> any HLTBSearching) {
        self.store = store
        self.makeSearch = makeSearch
        Task { [weak self] in await self?.reloadDismissedEstimates() }
    }

    func reloadDismissedEstimates() async {
        dismissedEstimateIDs = (try? await store.dismissedEstimateIDs()) ?? []
    }

    /// Whether a game's suspicious estimate was dismissed ("looks right").
    func isEstimateDismissed(_ gameID: Int64) -> Bool { dismissedEstimateIDs.contains(gameID) }

    /// Toggle "Estimate Looks Right" / "Flag again" for one game (PLAN §5.3, inspector).
    func setEstimateLooksRight(gameID: Int64, dismissed: Bool) {
        // Optimistic: update the cache now so the ⚠︎ flips at once; persist in the background.
        if dismissed { dismissedEstimateIDs.insert(gameID) } else { dismissedEstimateIDs.remove(gameID) }
        let store = self.store
        Task { [weak self] in
            try? await store.setEstimateLooksRight(gameID: gameID, dismissed: dismissed)
            await self?.reloadDismissedEstimates()
        }
    }

    // MARK: - Bulk (Game ▸ Fetch Missing Time Estimates…)

    var canRunBulk: Bool { library?.isLibraryGridDestination ?? false }

    func presentBulk() {
        guard bulk == nil, let library, canRunBulk else { return }
        let selection = library.selectedGameIDs
        let model = HLTBBulkFetchModel(store: store, makeSearch: makeSearch, mode: .fillGaps)
        bulk = model
        let store = self.store
        Task {
            let scope: [Int64]
            if selection.isEmpty {
                scope = (try? await store.gameIDsWithNoTimeEstimate()) ?? []
            } else {
                // The current selection, narrowed to games that still have a gap.
                let facts = (try? await store.timeToBeatFacts(gameIDs: Array(selection))) ?? [:]
                scope = facts.values.filter(\.hasAnyGap)
                    .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
                    .map(\.id)
            }
            model.start(gameIDs: scope)
        }
    }

    // MARK: - Bulk replace (Game / context ▸ Refresh Time Estimates from HowLongToBeat…)

    /// Present the **replace** bulk sheet for the selection, or — when nothing is
    /// selected — every currently-flagged game ("typically the filtered suspicious ones",
    /// PLAN §5.3). The sheet confirms the count before any request; one Undo restores the
    /// whole batch.
    func presentRefresh() {
        guard bulk == nil, let library, canRunBulk else { return }
        let selection = library.selectedGameIDs
        let model = HLTBBulkFetchModel(store: store, makeSearch: makeSearch, mode: .replace)
        model.onReplaceFinished = { [weak self] snapshots in
            self?.finishReplaceBatch(snapshots)
        }
        bulk = model
        let store = self.store
        Task {
            let scope: [Int64]
            if selection.isEmpty {
                scope = (try? await store.suspiciousEstimateGameIDs()) ?? []
            } else {
                scope = Array(selection).sorted()
            }
            model.start(gameIDs: scope)
        }
    }

    /// Register one Undo step for a finished replace batch and reload the dismissed cache
    /// (a replaced game's source becomes `hltb`, so it also leaves the flag) — PLAN §5.3.
    private func finishReplaceBatch(_ snapshots: [Int64: HLTBTimeSnapshot]) {
        Task { [weak self] in await self?.reloadDismissedEstimates() }
        guard let library, !snapshots.isEmpty else { return }
        let store = self.store
        library.undoManager?.registerUndo(withTarget: library) { _ in
            Task { try? await store.restoreTimeToBeatBatch(snapshots) }
        }
        library.undoManager?.setActionName("Refresh Time Estimates")
        let n = snapshots.count
        library.showBanner("Replaced times for \(n) game\(n == 1 ? "" : "s") from HowLongToBeat. Press ⌘Z to undo.", kind: .info)
    }

    func dismissBulk() { bulk?.cancel(); bulk = nil }

    // MARK: - Single game (inspector ▸ Fetch from HowLongToBeat)

    func fetchOne(gameID: Int64) { fetchOne(gameID: gameID, mode: .fillGaps) }

    /// Refresh one game from the inspector's ⚠︎ warning — **replaces** the three times
    /// when HLTB has the game, leaves it flagged otherwise (PLAN §5.3, D3).
    func refreshOne(gameID: Int64) { fetchOne(gameID: gameID, mode: .replace) }

    private func fetchOne(gameID: Int64, mode: HLTBWriteMode) {
        guard !isFetchingOne, let library else { return }
        isFetchingOne = true
        let search = makeSearch()
        let service = HLTBFillService(search: search)
        let store = self.store
        // An explicit inspector Refresh honours the 24 h cache floor (D1); a gap-fill takes
        // any fresh cache.
        let policy: HLTBFreshnessPolicy = mode == .replace ? .refresh : .cacheFirst
        Task { [weak self] in
            defer { self?.isFetchingOne = false }
            guard let facts = (try? await store.timeToBeatFacts(gameIDs: [gameID]))?[gameID] else { return }
            let slugs = facts.platformSlugSet
            do {
                // D4: a linked game refreshes exactly by its stored id — never ambiguous.
                if let hltbID = facts.hltbID {
                    switch try await service.resolveLinked(
                        title: facts.title, year: facts.year, hltbID: hltbID, librarySlugs: slugs, policy: policy) {
                    case .exact(let candidate):
                        await self?.applyConfident(gameID: gameID, candidate: candidate, mode: mode)
                        await search.rememberChosen(candidate)
                    case .lost(let outcome):
                        await self?.handleSingle(outcome, gameID: gameID, facts: facts, mode: mode,
                                                 search: search, lostLink: true)
                    }
                } else {
                    let outcome = try await service.resolve(
                        title: facts.title, year: facts.year, librarySlugs: slugs, policy: policy)
                    await self?.handleSingle(outcome, gameID: gameID, facts: facts, mode: mode,
                                             search: search, lostLink: false)
                }
            } catch let error as ImportError {
                library.showBanner(Self.stopMessage(error), kind: .error)
            } catch {
                library.showBanner("Couldn't reach HowLongToBeat.", kind: .error)
            }
        }
    }

    /// Route a single-game match outcome (D2/D4): apply a confident match (and remember it),
    /// raise the picker for an ambiguous one (with the game's platforms), or banner a miss.
    private func handleSingle(_ outcome: HLTBMatchOutcome, gameID: Int64, facts: HLTBGameFacts,
                              mode: HLTBWriteMode, search: any HLTBSearching, lostLink: Bool) async {
        guard let library else { return }
        switch outcome {
        case .confident(let candidate):
            await applyConfident(gameID: gameID, candidate: candidate, mode: mode)
            await search.rememberChosen(candidate)
        case .ambiguous(let list):
            if lostLink {
                library.showBanner("HowLongToBeat entry not found any more — pick again.", kind: .info)
            }
            picker = HLTBPickerRequest(gameID: gameID, title: facts.title, year: facts.year,
                                       candidates: list, mode: mode, librarySlugs: facts.platformSlugs)
        case .notFound:
            let note = lostLink
                ? "HowLongToBeat entry not found any more for “\(facts.title)”."
                : "No HowLongToBeat match for “\(facts.title)”."
            library.showBanner(note, kind: .info)
        }
    }

    /// The user picked one candidate from the single-game picker sheet — also remembers it
    /// under its id-key (D1) so the next refresh is exact.
    func pickForSingle(_ candidate: HLTBCandidate) {
        guard let request = picker else { return }
        picker = nil
        let search = makeSearch()
        Task {
            await applyConfident(gameID: request.gameID, candidate: candidate, mode: request.mode)
            await search.rememberChosen(candidate)
        }
    }

    func dismissPicker() { picker = nil }

    private func applyConfident(gameID: Int64, candidate: HLTBCandidate, mode: HLTBWriteMode) async {
        guard let library else { return }
        let result: HLTBFillResult?
        switch mode {
        case .fillGaps: result = try? await store.applyHLTBTimes(gameID: gameID, candidate: candidate)
        case .replace:  result = try? await store.replaceHLTBTimes(gameID: gameID, candidate: candidate)
        }
        guard let result else { return }
        if result.didWrite {
            registerUndo(gameID: gameID, snapshot: result.previous, mode: mode, library: library)
            await reloadDismissedEstimates()
            let verb = mode == .replace ? "Replaced" : "Filled"
            library.showBanner("\(verb) times from HowLongToBeat. Press ⌘Z to undo.", kind: .info)
        } else if mode == .replace {
            library.showBanner("HowLongToBeat doesn't have “\(candidate.name)”; the estimate stays flagged.", kind: .info)
        } else {
            library.showBanner("HowLongToBeat had no new times to add.", kind: .info)
        }
    }

    private func registerUndo(gameID: Int64, snapshot: HLTBTimeSnapshot, mode: HLTBWriteMode, library: LibraryViewModel) {
        let store = self.store
        library.undoManager?.registerUndo(withTarget: library) { _ in
            Task { try? await store.restoreTimeToBeat(gameID: gameID, snapshot) }
        }
        library.undoManager?.setActionName(mode == .replace ? "Refresh Time Estimate" : "Fetch Time Estimate")
    }

    static func stopMessage(_ error: ImportError) -> String {
        if case .rejected(let reject) = error {
            return "\(reject.reason.message) VGN stopped and made no further requests."
        }
        return "HowLongToBeat request stopped."
    }
}

// MARK: - Builder

/// Builds the HLTB fetch presenter for ``AppEnvironment`` (PLAN §5.3). **Live** mode
/// injects the real ``HLTBClient`` (its own budget/cache per run, keyed on a fresh
/// instance each fetch); every other mode uses the inert, no-network search — so the
/// whole UI is exercisable in sample/seeded/test mode without a request.
enum HLTBFetchBuilder {
    @MainActor
    static func build(mode: LaunchMode, database: AppDatabase,
                      library: LibraryViewModel) -> HLTBFetchPresenter {
        let store = LibraryStore(database)
        let makeSearch: @Sendable () -> any HLTBSearching
        if mode == .live {
            makeSearch = { HLTBClient(transport: URLSessionTransport(),
                                      cache: ImportResponseCacheStore(database)) }
        } else {
            makeSearch = { HLTBInertSearch() }
        }
        let presenter = HLTBFetchPresenter(store: store, makeSearch: makeSearch)
        presenter.library = library
        return presenter
    }
}

// MARK: - View hookup

private struct HLTBFetchPresentation: ViewModifier {
    let presenter: HLTBFetchPresenter?

    func body(content: Content) -> some View {
        if let presenter {
            content
                .sheet(isPresented: Binding(
                    get: { presenter.bulk != nil },
                    set: { if !$0 { presenter.dismissBulk() } }
                )) {
                    if let model = presenter.bulk {
                        HLTBBulkSheet(model: model, presenter: presenter) { presenter.dismissBulk() }
                    }
                }
                .sheet(item: Binding(
                    get: { presenter.picker },
                    set: { if $0 == nil { presenter.dismissPicker() } }
                )) { request in
                    HLTBPickerSheet(
                        title: request.title, year: request.year, candidates: request.candidates,
                        librarySlugs: request.librarySlugs,
                        onPick: { presenter.pickForSingle($0) },
                        onCancel: { presenter.dismissPicker() })
                }
                .focusedSceneValue(\.hltbFetchPresenter, presenter)
                .environment(\.hltbFetchPresenter, presenter)
        } else {
            content
        }
    }
}

/// Environment access to the presenter for in-window views (the inspector's
/// "Fetch from HowLongToBeat" button). Commands use the focused value above.
private struct HLTBFetchPresenterEnvironmentKey: EnvironmentKey {
    static let defaultValue: HLTBFetchPresenter? = nil
}

extension EnvironmentValues {
    var hltbFetchPresenter: HLTBFetchPresenter? {
        get { self[HLTBFetchPresenterEnvironmentKey.self] }
        set { self[HLTBFetchPresenterEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// Hosts the HLTB bulk-fetch sheet and single-game picker (PLAN §5.3).
    func hltbFetchPresentation(_ presenter: HLTBFetchPresenter?) -> some View {
        modifier(HLTBFetchPresentation(presenter: presenter))
    }
}

// MARK: - Focused value + command

struct HLTBFetchPresenterFocusedValueKey: FocusedValueKey {
    typealias Value = HLTBFetchPresenter
}

extension FocusedValues {
    var hltbFetchPresenter: HLTBFetchPresenter? {
        get { self[HLTBFetchPresenterFocusedValueKey.self] }
        set { self[HLTBFetchPresenterFocusedValueKey.self] = newValue }
    }
}
