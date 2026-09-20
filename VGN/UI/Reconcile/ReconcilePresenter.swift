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
    /// The active bundle-expansion confirm sheet, or nil (PLAN §5.1).
    var bundleExpansion: BundleExpansionModel?
    /// The active "Expand All Unplayed" batch sheet, or nil (PLAN §13.3 / §5.1 D4b).
    var batchExpand: BundleBatchExpandModel?
    /// Notified after a bundle expansion or a "not a bundle" dismissal, so a live
    /// Bundles-to-Expand list (PLAN §5.1) can reload. A no-op unless a list is showing.
    var onBundleCandidatesChanged: () -> Void = {}

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

    /// "Merge into the Original…" (PLAN §5.1 "Same Game, Two Entries"): find the library
    /// original of this port and open the existing merge confirm sheet with it as target.
    /// No new merge code — reuses ``beginMerge`` (rules + sheet + undo).
    func presentMergeIntoOriginal(for portGameID: Int64) {
        Task {
            guard let target = try? await store.originalGameID(forPort: portGameID) else {
                vm?.showBanner("Couldn't find the original in your library.", kind: .error); return
            }
            let title = (try? await store.gameDetail(id: target))?.title ?? "the original"
            beginMerge(source: portGameID, target: target, targetTitle: title)
        }
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

    private func dismiss() { link = nil; merge = nil; bundleExpansion = nil }

    private func handleChoice(gameID: Int64, isLinked: Bool, choice: IGDBLinkChoice) {
        if choice.isBundle {
            beginBundleExpansion(gameID: gameID, bundleIGDBID: choice.igdbID, bundleTitle: choice.title)
        } else if let existing = choice.existingGameID {
            beginMerge(source: gameID, target: existing, targetTitle: choice.title)
        } else {
            Task { await performLinkOrRelink(gameID: gameID, isLinked: isLinked, choice: choice) }
        }
    }

    // MARK: - Bundle expansion (PLAN §5.1)

    /// D3 repair entry point: expand a library game that is already linked to an IGDB
    /// bundle. Resolves the game's IGDB id, verifies on demand (no-op with a clear message
    /// when it is not a bundle / has no members), then opens the same confirm sheet.
    func presentBundleExpansion(for gameID: Int64) {
        Task {
            guard let preview = try? await store.bundleExpansionPreview(gameID: gameID) else {
                vm?.showBanner("Couldn't open the game.", kind: .error); return
            }
            guard let igdbID = preview.igdbID else {
                vm?.showBanner("Link this game to IGDB first, then expand it.", kind: .info); return
            }
            await runBundleExpansion(gameID: gameID, bundleIGDBID: igdbID, bundleTitle: preview.title)
        }
    }

    // MARK: - Expand All Unplayed (batch, PLAN §13.3 / §5.1 D4b)

    /// Expand every bundle candidate that carries no play data in one pass: fetch members one game
    /// at a time (progress modal, cancellable), one confirmation, one undo step. Played placeholders
    /// are left for the per-game sheet (D4c). Wired to the Bundles-to-Expand header button.
    func expandAllUnplayedBundles() {
        Task {
            let candidates = (try? await store.unplayedBundleExpansionCandidates()) ?? []
            guard !candidates.isEmpty else {
                vm?.showBanner("No unplayed bundles to expand.", kind: .info); return
            }
            let searcher = self.searcher
            let model = BundleBatchExpandModel(store: store, membersOf: { candidate in
                guard let igdbID = candidate.igdbID else { return [] }
                let raw = (try? await searcher.bundleMembers(bundleIGDBID: igdbID)) ?? []
                return ImportBundleMapping.members(from: raw)
            })
            model.onClose = { [weak self] in self?.batchExpand = nil }
            model.onFinished = { [weak self] finished in
                guard let self else { return }
                self.registerBatchUndo(finished)
                if finished.expandedCount > 0 {
                    self.vm?.showBanner("Expanded \(finished.expandedCount) bundle\(finished.expandedCount == 1 ? "" : "s").", kind: .info)
                }
                self.onBundleCandidatesChanged()
                self.batchExpand = nil
            }
            batchExpand = model
            await model.run(candidates)
        }
    }

    private func registerBatchUndo(_ model: BundleBatchExpandModel) {
        guard model.expandedCount > 0, let um = vm?.undoManager else { return }
        let records = model.undoRecords
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in
                for undo in records.reversed() { try? await target.store.restoreBundleExpansion(undo) }
            }
        }
        um.setActionName("Expand Bundles")
    }

    private func beginBundleExpansion(gameID: Int64, bundleIGDBID: Int64, bundleTitle: String) {
        Task { await runBundleExpansion(gameID: gameID, bundleIGDBID: bundleIGDBID, bundleTitle: bundleTitle) }
    }

    private func runBundleExpansion(gameID: Int64, bundleIGDBID: Int64, bundleTitle: String) async {
        let raw = (try? await searcher.bundleMembers(bundleIGDBID: bundleIGDBID)) ?? []
        let members = ImportBundleMapping.members(from: raw)
        guard !members.isEmpty else {
            link = nil
            // Remember it is not a bundle so it leaves the Bundles-to-Expand list for good (§5.1).
            try? await store.dismissBundleCandidate(gameID: gameID)
            onBundleCandidatesChanged()
            vm?.showBanner("That’s not a bundle on IGDB — nothing to expand.", kind: .info)
            return
        }
        let preview = try? await store.bundleExpansionPreview(gameID: gameID)
        let model = BundleExpansionModel(
            gameID: gameID, bundleTitle: bundleTitle, members: members,
            carriesPlayData: preview?.carriesPlayData ?? false,
            isPlayed: preview?.isPlayed ?? false, isRanked: preview?.isRanked ?? false)
        model.onCancel = { [weak self] in self?.dismiss() }
        model.onConfirm = { [weak self] m in
            self?.performExpansion(gameID: gameID, bundleTitle: bundleTitle,
                                   members: m.resolvedMembers, targetIndex: m.effectiveTargetIndex)
        }
        link = nil
        merge = nil
        bundleExpansion = model
    }

    private func performExpansion(gameID: Int64, bundleTitle: String,
                                  members: [CompilationMemberDraft], targetIndex: Int?) {
        Task {
            vm?.planReselectionAfterMutation([gameID])
            do {
                let result = try await store.expandBundle(
                    gameID: gameID, bundleTitle: bundleTitle, members: members,
                    playDataTargetIndex: targetIndex)
                for memberID in result.memberGameIDs { onEnrich(memberID, false) }
                vm?.showBanner("Expanded into \(result.memberGameIDs.count) games.", kind: .info)
                onBundleCandidatesChanged()
                registerBundleUndo(result.undo)
            } catch {
                vm?.showBanner("Couldn't expand the bundle.", kind: .error)
            }
            bundleExpansion = nil
        }
    }

    private func registerBundleUndo(_ undo: BundleExpansionUndo) {
        guard let um = vm?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.undoBundleExpansion(undo) }
        }
        um.setActionName(undo.actionName)
    }

    /// Restore a bundle-expansion snapshot (undo). `internal` so a test drives it directly
    /// (`UndoManager.undo()` hangs headless).
    func undoBundleExpansion(_ undo: BundleExpansionUndo) async {
        do { try await store.restoreBundleExpansion(undo) }
        catch { vm?.showBanner("Couldn't undo.", kind: .error) }
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
            .sheet(item: $presenter.bundleExpansion) { model in
                BundleExpansionSheet(model: model)
            }
            .sheet(item: $presenter.batchExpand) { model in
                BundleBatchExpandSheet(model: model)
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
