import SwiftUI

/// Owns the reconcile flow (PLAN §5.1): opens the link / change-match search sheet,
/// routes a chosen IGDB target to LINK / RE-LINK / MERGE, performs the store write,
/// registers undo, kicks enrichment, and moves the selection when a game leaves the
/// list. `@MainActor @Observable`; built once in ``AppEnvironment`` and presented by
/// `.igdbLinkPresentation` (attached in `VGNApp`). Nil in the XCTest host.
@MainActor
@Observable
final class IGDBLinkPresenter {
    /// The active search sheet, or nil.
    var link: IGDBLinkModel?
    /// The active merge confirmation sheet, or nil.
    var merge: IGDBMergeModel?

    private let store: LibraryStore
    private weak var vm: LibraryViewModel?
    private let searcher: any CatalogSearching
    /// slug → IGDB platform ids (from the platform catalogue); empty ⇒ no toggle.
    private let platformIGDBIDs: @Sendable (String) -> [Int]
    /// Kick enrichment for a game after a link / re-link (gameID, force). Wired live to
    /// clear the cover negative cache + refresh/notify the coordinator; a no-op offline.
    private let onEnrich: (Int64, Bool) -> Void
    /// Injectable clock-free search seam for the model (tests pass an immediate sleep).
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        store: LibraryStore,
        vm: LibraryViewModel,
        searcher: any CatalogSearching,
        platformIGDBIDs: @escaping @Sendable (String) -> [Int] = { _ in [] },
        onEnrich: @escaping (Int64, Bool) -> Void = { _, _ in },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.vm = vm
        self.searcher = searcher
        self.platformIGDBIDs = platformIGDBIDs
        self.onEnrich = onEnrich
        self.sleep = sleep
    }

    // MARK: - Entry point

    /// Open the link / change-match sheet for one game (inspector, grid, menu).
    func present(for gameID: Int64) {
        Task { await beginLink(gameID) }
    }

    private func beginLink(_ gameID: Int64) async {
        guard let detail = try? await store.gameDetail(id: gameID) else {
            vm?.showBanner("Couldn't open the game.", kind: .error); return
        }
        let index = (try? await store.igdbLinkIndex()) ?? [:]
        let igdbIDs = detail.platformIDs.flatMap(platformIGDBIDs)
        let isLinked = detail.igdbID != nil
        let model = IGDBLinkModel(
            gameID: gameID, currentTitle: detail.title, platformSlugs: detail.platformIDs,
            year: detail.year, isLinked: isLinked, prefill: IGDBLinkQuery.clean(detail.title),
            searcher: searcher, platformIGDBIDs: igdbIDs, libraryIndex: index, sleep: sleep)
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onChoose = { [weak self] choice in
            self?.handleChoice(gameID: gameID, isLinked: isLinked, choice: choice)
        }
        merge = nil
        link = model
    }

    private func dismiss() { link = nil; merge = nil }

    private func handleChoice(gameID: Int64, isLinked: Bool, choice: IGDBLinkChoice) {
        if let existing = choice.existingGameID {
            beginMerge(source: gameID, target: existing, targetTitle: choice.title)
        } else {
            Task { await performLinkOrRelink(gameID: gameID, isLinked: isLinked, choice: choice) }
        }
    }

    // MARK: - Link / re-link

    private func performLinkOrRelink(gameID: Int64, isLinked: Bool, choice: IGDBLinkChoice) async {
        vm?.planReselectionAfterMutation([gameID])
        do {
            let undo: ReconcileUndo
            if isLinked {
                undo = try await store.relinkGameInPlace(
                    gameID: gameID, igdbID: choice.igdbID, igdbTitle: choice.title)
                onEnrich(gameID, true)          // force: clear stale + re-fetch
                vm?.showBanner("Changed IGDB match — refreshing metadata.", kind: .info)
            } else {
                undo = try await store.linkGameToIGDB(
                    gameID: gameID, igdbID: choice.igdbID, igdbTitle: choice.title)
                onEnrich(gameID, false)         // fill-only, like a fresh IGDB game
                vm?.showBanner("Linked to IGDB — fetching metadata.", kind: .info)
            }
            registerUndo(undo) { [weak self] in
                Task { await self?.performLinkOrRelink(gameID: gameID, isLinked: isLinked, choice: choice) }
            }
        } catch {
            vm?.showBanner("Couldn't link the game.", kind: .error)
        }
        link = nil
    }

    // MARK: - Merge

    private func beginMerge(source: Int64, target: Int64, targetTitle: String) {
        Task {
            guard let inputs = try? await store.mergeInputs(sourceGameID: source, targetGameID: target) else {
                vm?.showBanner("Couldn't prepare the merge.", kind: .error); return
            }
            let model = IGDBMergeModel(inputs: inputs)
            model.onCancel = { [weak self] in self?.dismiss() }
            model.onConfirm = { [weak self] decisions in
                self?.performMerge(source: source, target: target, targetTitle: inputs.targetTitle, decisions: decisions)
            }
            link = nil
            merge = model
        }
    }

    private func performMerge(source: Int64, target: Int64, targetTitle: String, decisions: [CopyMergeDecision]) {
        Task {
            vm?.planReselectionAfterMutation([source])
            do {
                let undo = try await store.mergeGame(sourceGameID: source, into: target, decisions: decisions)
                if vm?.selectedGameIDs.contains(source) == true { vm?.selectOnly(target) }
                onEnrich(target, false)
                vm?.showBanner("Merged into \u{201C}\(targetTitle)\u{201D}.", kind: .info)
                registerUndo(undo) { [weak self] in
                    self?.performMerge(source: source, target: target, targetTitle: targetTitle, decisions: decisions)
                }
            } catch {
                vm?.showBanner("Couldn't merge the games.", kind: .error)
            }
            merge = nil
        }
    }

    // MARK: - Undo (restore the snapshot; register the re-apply as redo)

    private func registerUndo(_ snapshot: ReconcileUndo, redo: @escaping @MainActor () -> Void) {
        guard let um = vm?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.undoReconcile(snapshot, redo: redo) }
        }
        um.setActionName(snapshot.actionName)
    }

    /// Restore a reconcile snapshot (undo) and register the re-apply as redo. `internal`
    /// so a test drives it directly (`UndoManager.undo()` hangs headless).
    func undoReconcile(_ snapshot: ReconcileUndo, redo: @escaping @MainActor () -> Void) async {
        do { try await store.restoreReconcile(snapshot) }
        catch { vm?.showBanner("Couldn't undo.", kind: .error); return }
        if let um = vm?.undoManager {
            um.registerUndo(withTarget: self) { _ in Task { @MainActor in redo() } }
            um.setActionName(snapshot.actionName)
        }
    }
}

// MARK: - Catalogue searcher environment seam

/// Carries the shared IGDB catalogue searcher into the view tree so the import review
/// sheet's inline "Find…" (PLAN §5.1 item 6) can search without the PSN-lane importer
/// builders having to thread a searcher through. Injected once in `VGNApp`; nil offline.
private struct IGDBCatalogSearcherKey: EnvironmentKey {
    static let defaultValue: (any CatalogSearching)? = nil
}

extension EnvironmentValues {
    var igdbCatalogSearcher: (any CatalogSearching)? {
        get { self[IGDBCatalogSearcherKey.self] }
        set { self[IGDBCatalogSearcherKey.self] = newValue }
    }
}

// MARK: - Presentation

private struct IGDBLinkPresentationModifier: ViewModifier {
    @Bindable var presenter: IGDBLinkPresenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.link) { model in
                IGDBLinkSheet(model: model)
            }
            .sheet(item: $presenter.merge) { model in
                IGDBMergeSheet(model: model)
            }
    }
}

extension View {
    /// Presents the reconcile link + merge sheets from `presenter` (PLAN §5.1). Attached
    /// once in `VGNApp`; a nil presenter (XCTest host) is a no-op.
    @ViewBuilder
    func igdbLinkPresentation(_ presenter: IGDBLinkPresenter?) -> some View {
        if let presenter {
            modifier(IGDBLinkPresentationModifier(presenter: presenter))
        } else {
            self
        }
    }
}
