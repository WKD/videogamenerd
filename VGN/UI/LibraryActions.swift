import Foundation

/// Turns the library's UI intents into ``LibraryStore`` writes (PLAN §8): every
/// write is async, its errors surface in a non-blocking banner (never swallowed),
/// invariant violations become confirmations, and reversible intents register an
/// inverse with the window's `UndoManager`.
///
/// Owned by the app's `AppEnvironment`; it reads the selection and writes
/// feedback state through a weak ``LibraryViewModel``. Tested end-to-end against
/// an in-memory `LibraryStore`.
@MainActor
final class LibraryActions {
    let store: LibraryStore
    weak var vm: LibraryViewModel?

    /// Seam for the services lane's post-merge hookup: called after any
    /// successful write so the services coordinator can react (e.g.
    /// `coordinator.notifyLibraryChanged()` — kick enrichment). No-op until wired;
    /// the GRDB observations already refresh the UI on their own.
    var onLibraryChanged: () -> Void = {}

    init(store: LibraryStore, vm: LibraryViewModel) {
        self.store = store
        self.vm = vm
    }

    private func notifyLibraryChanged() { onLibraryChanged() }

    /// Point the view model's intent seams at this object. Called once by the app.
    func install() {
        guard let vm else { return }
        vm.actions = self
        vm.onSetTier = { [weak self] ids, letter in
            Task { await self?.setTier(ids: ids, letter: letter) }
        }
        vm.onSetOwned = { [weak self] ids, value in
            Task { await self?.setOwned(ids: ids, owned: value) }
        }
        vm.onSetPlayed = { [weak self] ids, value in
            Task { await self?.setPlayed(ids: ids, played: value) }
        }
        vm.onShowInspector = {}
        vm.onQuickAdd = { [weak self] in self?.vm?.quickAddPresented = true }
    }

    // MARK: - Tier (undoable; skips unplayed games)

    func setTier(ids: Set<Int64>, letter: String?) async {
        guard !ids.isEmpty else { return }
        let tierID = letter.flatMap { l in vm?.tiers.first { $0.letter == l }?.id }
        let previous = capturePreviousTiers(ids)
        do {
            let outcome = try await store.setTier(Array(ids), tierID: tierID)
            if !outcome.skippedUnplayed.isEmpty {
                let n = outcome.skippedUnplayed.count
                vm?.showBanner("\(n) game\(n == 1 ? "" : "s") skipped — mark \(n == 1 ? "it" : "them") played first.",
                               kind: .warning)
            }
            registerTierUndo(previous)
        } catch {
            vm?.showBanner("Couldn't change tier.", kind: .error)
        }
    }

    private func capturePreviousTiers(_ ids: Set<Int64>) -> [Int64: Int64?] {
        guard let vm else { return [:] }
        var out: [Int64: Int64?] = [:]
        for id in ids { out[id] = vm.games.first { $0.id == id }?.tierID }
        return out
    }

    private func registerTierUndo(_ previous: [Int64: Int64?]) {
        guard let undo = vm?.undoManager, !previous.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restoreTiers(previous) }
        }
        undo.setActionName("Set Tier")
    }

    /// Apply a captured `[gameID: tierID]` map (the inverse of a tier change).
    /// Invoked by the registered undo; `internal` so a test can exercise the
    /// inverse without driving `UndoManager.undo()` (whose run-loop machinery
    /// deadlocks in a headless test host).
    func restoreTiers(_ previous: [Int64: Int64?]) async {
        let redo = capturePreviousTiers(Set(previous.keys))
        // Group ids by the tier they should return to, one write per group.
        let byTier = Dictionary(grouping: previous.keys) { previous[$0] ?? nil }
        for (tierID, ids) in byTier {
            _ = try? await store.setTier(ids, tierID: tierID)
        }
        registerTierUndo(redo)
    }

    // MARK: - Played (undoable; orphan confirmation on un-play)

    func setPlayed(ids: Set<Int64>, played: Bool) async {
        guard !ids.isEmpty else { return }
        let previous = capturePreviousPlayed(ids)
        do {
            let outcome = try await store.setPlayed(Array(ids), played)
            switch outcome {
            case .ok:
                registerPlayedUndo(previous)
            case .wouldOrphan(let orphans):
                confirmOrphan(
                    ids: orphans,
                    action: "is no longer owned or played",
                    onConfirm: { [weak self] in
                        Task { _ = try? await self?.store.setPlayed(Array(ids), played, confirmOrphanDelete: true) }
                    }
                )
            }
        } catch {
            vm?.showBanner("Couldn't change played state.", kind: .error)
        }
    }

    private func capturePreviousPlayed(_ ids: Set<Int64>) -> [Int64: Bool] {
        guard let vm else { return [:] }
        var out: [Int64: Bool] = [:]
        for id in ids { out[id] = vm.games.first { $0.id == id }?.played ?? false }
        return out
    }

    private func registerPlayedUndo(_ previous: [Int64: Bool]) {
        guard let undo = vm?.undoManager, !previous.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restorePlayed(previous) }
        }
        undo.setActionName("Mark Played")
    }

    private func restorePlayed(_ previous: [Int64: Bool]) async {
        let redo = capturePreviousPlayed(Set(previous.keys))
        let byValue = Dictionary(grouping: previous.keys) { previous[$0] ?? false }
        for (value, ids) in byValue {
            _ = try? await store.setPlayed(ids, value, confirmOrphanDelete: true)
        }
        registerPlayedUndo(redo)
    }

    // MARK: - Status (undoable)

    func setStatus(ids: Set<Int64>, status: PlayStatus?) async {
        guard !ids.isEmpty else { return }
        let previous = capturePreviousStatus(ids)
        do {
            try await store.setStatus(Array(ids), status)
            registerStatusUndo(previous)
        } catch {
            vm?.showBanner("Couldn't change status.", kind: .error)
        }
    }

    private func capturePreviousStatus(_ ids: Set<Int64>) -> [Int64: PlayStatus?] {
        guard let vm else { return [:] }
        var out: [Int64: PlayStatus?] = [:]
        for id in ids {
            if id == vm.selectedDetail?.id { out[id] = vm.selectedDetail?.status }
            else { out[id] = vm.games.first { $0.id == id }?.status }
        }
        return out
    }

    private func registerStatusUndo(_ previous: [Int64: PlayStatus?]) {
        guard let undo = vm?.undoManager, !previous.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restoreStatus(previous) }
        }
        undo.setActionName("Set Status")
    }

    private func restoreStatus(_ previous: [Int64: PlayStatus?]) async {
        let redo = capturePreviousStatus(Set(previous.keys))
        let byStatus = Dictionary(grouping: previous.keys) { previous[$0] ?? nil }
        for (status, ids) in byStatus {
            try? await store.setStatus(ids, status)
        }
        registerStatusUndo(redo)
    }

    // MARK: - My playtime (undoable)

    func setMyPlaytime(gameID: Int64, seconds: Int?) async {
        let previous = vm?.selectedDetail?.id == gameID ? vm?.selectedDetail?.myPlaytimeS : nil
        do {
            try await store.setMyPlaytime(gameID: gameID, seconds: seconds)
            registerPlaytimeUndo(gameID: gameID, previous: previous ?? nil)
        } catch {
            vm?.showBanner("Couldn't save playtime.", kind: .error)
        }
    }

    private func registerPlaytimeUndo(gameID: Int64, previous: Int?) {
        guard let undo = vm?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restorePlaytime(gameID: gameID, previous: previous) }
        }
        undo.setActionName("Edit Playtime")
    }

    private func restorePlaytime(gameID: Int64, previous: Int?) async {
        let redo = vm?.selectedDetail?.id == gameID ? (vm?.selectedDetail?.myPlaytimeS ?? nil) : nil
        try? await store.setMyPlaytime(gameID: gameID, seconds: previous)
        registerPlaytimeUndo(gameID: gameID, previous: redo)
    }

    // MARK: - Owned

    func setOwned(ids: Set<Int64>, owned: Bool) async {
        guard !ids.isEmpty else { return }
        if owned { await addOwnership(ids: ids) }
        else { await removeOwnership(ids: ids) }
    }

    /// Mark game(s) owned. A single game with several platforms opens a picker;
    /// otherwise a physical copy is added on each game's primary platform.
    private func addOwnership(ids: Set<Int64>) async {
        guard let vm else { return }
        // Single game with a choice of platform → ask.
        if ids.count == 1, let id = ids.first,
           let summary = vm.games.first(where: { $0.id == id }),
           summary.platformIDs.count > 1 {
            await requestOwnershipCopy(gameID: id, title: summary.title, platforms: summary.platformIDs)
            return
        }
        // Bulk / single-platform: add a physical copy on the primary platform.
        var added = 0
        var skipped = 0
        for id in ids {
            guard let summary = vm.games.first(where: { $0.id == id }) else { continue }
            if summary.owned { skipped += 1; continue }
            guard let platform = summary.platformIDs.first else { skipped += 1; continue }
            do { _ = try await store.addCopy(gameID: id, platformID: platform); added += 1 }
            catch { vm.showBanner("Couldn't add a copy.", kind: .error); return }
        }
        if added > 0 { notifyLibraryChanged() }
        if added == 0 && skipped > 0 {
            vm.showBanner("Already owned.", kind: .info)
        }
    }

    /// Inspector "Add copy…": always open the platform/format picker.
    func requestAddCopy(gameID: Int64, title: String, platforms: [String]) {
        Task { await requestOwnershipCopy(gameID: gameID, title: title, platforms: platforms) }
    }

    /// Inspector remove-copy button: remove one product (may orphan → confirm).
    func removeCopy(productID: Int64, gameTitle: String) {
        Task { await performCopyRemoval([productID], gameTitle: gameTitle) }
    }

    private func requestOwnershipCopy(gameID: Int64, title: String, platforms: [String]) async {
        let all = (try? await store.allPlatforms()) ?? []
        let bySlug = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gamePlatforms = platforms.compactMap { bySlug[$0] ?? PlatformLabels.info($0) }
        vm?.ownershipRequest = OwnershipRequest(
            gameID: gameID, title: title,
            gamePlatforms: gamePlatforms,
            allPlatforms: all.isEmpty ? PlatformLabels.all : all,
            perform: { [weak self] platformID, format in
                Task {
                    do {
                        _ = try await self?.store.addCopy(gameID: gameID, platformID: platformID, format: format)
                        self?.notifyLibraryChanged()
                    }
                    catch { self?.vm?.showBanner("Couldn't add a copy.", kind: .error) }
                }
            }
        )
    }

    /// Un-own a game: choose which copies to remove; compilation copies warn.
    private func removeOwnership(ids: Set<Int64>) async {
        guard let id = ids.first else { return }
        guard let detail = try? await store.gameDetail(id: id), !detail.copies.isEmpty else { return }

        // One plain copy → confirm removal directly (may orphan).
        if detail.copies.count == 1, let only = detail.copies.first, !only.isCompilation {
            await performCopyRemoval([only.productID], gameTitle: detail.title)
            return
        }

        let choices: [CopyRemovalRequest.Choice] = detail.copies.map { copy in
            CopyRemovalRequest.Choice(
                productID: copy.productID,
                label: copyLabel(copy),
                isCompilation: copy.isCompilation,
                compilationMembers: copy.isCompilation ? compilationMemberTitles(copy) : []
            )
        }
        vm?.copyRemovalRequest = CopyRemovalRequest(
            title: detail.title,
            copies: choices,
            perform: { [weak self] productIDs in
                Task { await self?.performCopyRemoval(productIDs, gameTitle: detail.title) }
            }
        )
    }

    private func performCopyRemoval(_ productIDs: [Int64], gameTitle: String) async {
        guard !productIDs.isEmpty else { return }
        var wouldOrphanProducts: [Int64] = []
        for pid in productIDs {
            do {
                let outcome = try await store.removeProduct(pid)
                if case .wouldOrphan = outcome { wouldOrphanProducts.append(pid) }
            } catch {
                vm?.showBanner("Couldn't remove the copy.", kind: .error); return
            }
        }
        guard !wouldOrphanProducts.isEmpty else { return }
        confirmOrphan(
            title: "\u{201C}\(gameTitle)\u{201D} is neither owned nor played any more — delete it from the library?",
            onConfirm: { [weak self] in
                Task {
                    for pid in wouldOrphanProducts {
                        _ = try? await self?.store.removeProduct(pid, confirmOrphanDelete: true)
                    }
                }
            }
        )
    }

    private func copyLabel(_ copy: GameDetail.Copy) -> String {
        var parts = [PlatformLabels.short(copy.platformID), copy.format.rawValue.capitalized]
        if let edition = copy.edition, !edition.isEmpty { parts.append(edition) }
        if copy.isCompilation, let title = copy.title, !title.isEmpty {
            parts.append("in \(title)")
        }
        return parts.joined(separator: " · ")
    }

    private func compilationMemberTitles(_ copy: GameDetail.Copy) -> [String] {
        // The member titles aren't on the Copy; show the product title + count.
        if let title = copy.title { return ["\(title) (\(copy.memberCount) games)"] }
        return ["\(copy.memberCount) games"]
    }

    // MARK: - Delete (confirmed; not undoable)

    func requestDelete(ids: Set<Int64>) {
        guard let vm, !ids.isEmpty else { return }
        let titles = ids.compactMap { id in vm.games.first { $0.id == id }?.title }
        let name = titles.count == 1 ? "\u{201C}\(titles[0])\u{201D}"
            : "\(ids.count) games"
        vm.pendingConfirmation = LibraryConfirmation(
            title: "Delete \(name)?",
            message: "This permanently removes \(ids.count == 1 ? "it" : "them") from the library. This can't be undone.",
            confirmTitle: "Delete",
            isDestructive: true,
            perform: { [weak self] in
                Task { await self?.performDelete(ids: ids) }
            }
        )
    }

    private func performDelete(ids: Set<Int64>) async {
        for id in ids {
            do { try await store.deleteGame(id) }
            catch { vm?.showBanner("Couldn't delete a game.", kind: .error); return }
        }
        vm?.selectedGameIDs.subtract(ids)
    }

    // MARK: - Manual add (until Quick Add lands)

    @discardableResult
    func addManualGame(_ draft: GameDraft) async -> Bool {
        do {
            _ = try await store.addGame(draft)
            notifyLibraryChanged()
            return true
        } catch {
            vm?.showBanner("Couldn't add the game.", kind: .error)
            return false
        }
    }

    // MARK: - Confirmation helpers

    private func confirmOrphan(ids: [Int64], action: String, onConfirm: @escaping () -> Void) {
        guard let vm else { return }
        let titles = ids.compactMap { id in vm.games.first { $0.id == id }?.title }
        let name = titles.count == 1 ? "\u{201C}\(titles[0])\u{201D}"
            : "\(ids.count) games"
        confirmOrphan(
            title: "\(name) \(action) — delete from the library?",
            onConfirm: onConfirm
        )
    }

    private func confirmOrphan(title: String, onConfirm: @escaping () -> Void) {
        vm?.pendingConfirmation = LibraryConfirmation(
            title: title,
            message: "A game must be owned or played. Removing the last of both deletes it.",
            confirmTitle: "Delete",
            isDestructive: true,
            perform: onConfirm
        )
    }
}
