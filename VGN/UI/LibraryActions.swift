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
        vm.onMarkPlayed = { [weak self] ids, mark in
            Task { await self?.markPlayed(ids: ids, mark: mark) }
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

    // MARK: - "Holds up today?" (undoable; PLAN §7b, v16)

    /// Set (or clear) the "Holds up today?" mark on a set of games — one transaction, one
    /// "Holds Up Today?" undo step. Unplayed games are refused by the store and named in a
    /// warning banner (only a played game can be judged today).
    func setHoldsUp(ids: Set<Int64>, value: HoldsUp?) async {
        guard !ids.isEmpty else { return }
        do {
            let outcome = try await store.setHoldsUp(value, for: Array(ids).sorted())
            if !outcome.skippedUnplayed.isEmpty {
                vm?.showBanner(Self.holdsUpSkippedBanner(outcome.skippedUnplayed.count), kind: .warning)
            }
            let changed = outcome.previous.filter { $0.value != value }
            registerHoldsUpUndo(changed)
        } catch {
            vm?.showBanner("Couldn't save the \"Holds up today?\" mark.", kind: .error)
        }
    }

    nonisolated static func holdsUpSkippedBanner(_ n: Int) -> String {
        "^[\(n) unplayed game](inflect: true) skipped — only a played game can be rated."
    }

    private func registerHoldsUpUndo(_ previous: [Int64: HoldsUp?]) {
        guard let undo = vm?.undoManager, !previous.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restoreHoldsUp(previous) }
        }
        undo.setActionName(Self.holdsUpUndoName)
    }

    /// The undo step's name (menu: "Undo Holds Up Today?").
    nonisolated static let holdsUpUndoName = "Holds Up Today?"

    /// Apply a captured `[gameID: mark]` map (the inverse of ``setHoldsUp(ids:value:)``) and
    /// register the swapped step so undo ↔ redo alternate. `internal` so a test drives the
    /// inverse directly (`UndoManager.undo()` hangs headless).
    func restoreHoldsUp(_ previous: [Int64: HoldsUp?]) async {
        do {
            let redo = try await store.restoreHoldsUp(previous)
            registerHoldsUpUndo(redo)
        } catch {
            vm?.showBanner("Couldn't undo.", kind: .error)
        }
    }

    // MARK: - Mark Played As (undoable; PLAN §8, owner request 2026-09-19)

    /// Mark a set of games played (optionally with a completion status) in one
    /// transaction, with one undo step for the whole batch and a summary banner.
    /// `.played` leaves an existing status alone; `.status(x)` also sets the status.
    func markPlayed(ids: Set<Int64>, mark: PlayedMark) async {
        guard !ids.isEmpty else { return }
        let previous = capturePreviousPlayState(ids)
        let (changed, already) = classifyMark(ids, mark: mark, previous: previous)
        do {
            try await store.markPlayed(Array(ids), status: mark.status)
            registerMarkPlayedUndo(previous, actionName: mark.menuTitle)
            vm?.showBanner(PlayedMarkFeedback.banner(mark: mark, changed: changed, already: already),
                           kind: .info)
        } catch {
            vm?.showBanner("Couldn't mark the games played.", kind: .error)
        }
    }

    /// Count how many games this mark actually moves vs. how many already sit in
    /// the target state (for the banner). `.played` = "already" iff already played;
    /// `.status(x)` = "already" iff already played **and** already status `x`.
    private func classifyMark(_ ids: Set<Int64>, mark: PlayedMark,
                              previous: [Int64: PriorPlayState]) -> (changed: Int, already: Int) {
        var already = 0
        for id in ids {
            guard let prior = previous[id] else { continue }
            let unchanged: Bool
            switch mark {
            case .played: unchanged = prior.played
            case let .status(s): unchanged = prior.played && prior.status == s
            }
            if unchanged { already += 1 }
        }
        return (ids.count - already, already)
    }

    private func capturePreviousPlayState(_ ids: Set<Int64>) -> [Int64: PriorPlayState] {
        guard let vm else { return [:] }
        var out: [Int64: PriorPlayState] = [:]
        for id in ids {
            if id == vm.selectedDetail?.id, let detail = vm.selectedDetail {
                out[id] = PriorPlayState(played: detail.played, status: detail.status)
            } else if let summary = vm.games.first(where: { $0.id == id }) {
                out[id] = PriorPlayState(played: summary.played, status: summary.status)
            }
        }
        return out
    }

    private func registerMarkPlayedUndo(_ previous: [Int64: PriorPlayState], actionName: String) {
        guard let undo = vm?.undoManager, !previous.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.restoreMarkPlayed(previous, actionName: actionName) }
        }
        undo.setActionName(actionName)
    }

    /// Restore each game's exact prior played + status. A game that was **unplayed**
    /// before is un-played again — *unless* it was tiered since the mark, in which
    /// case un-playing would strip a valid tier (invariant 2); it is left played and
    /// called out in a banner. A game that was already played only has its status
    /// restored (its played flag never changed). `internal` so a test can drive the
    /// inverse directly (`UndoManager.undo()` deadlocks headless).
    func restoreMarkPlayed(_ previous: [Int64: PriorPlayState], actionName: String) async {
        let redo = capturePreviousPlayState(Set(previous.keys))
        var keptTiered: [Int64] = []
        for (id, prior) in previous {
            if prior.played {
                // Played before the mark → only the status may have changed.
                try? await store.setStatus([id], prior.status)
            } else {
                // Unplayed before the mark. If it has since been tiered, un-playing
                // would clear that tier — skip it (leave it played).
                let nowTiered = vm?.games.first { $0.id == id }?.tierID != nil
                if nowTiered { keptTiered.append(id); continue }
                _ = try? await store.setPlayed([id], false, confirmOrphanDelete: true)
            }
        }
        registerMarkPlayedUndo(redo, actionName: actionName)
        if !keptTiered.isEmpty {
            let n = keptTiered.count
            vm?.showBanner("^[\(n) game](inflect: true) kept played — ranked since the mark.", kind: .info)
        }
    }

    // MARK: - Change Copy Format (undoable; PLAN §13.3)

    /// Bulk-set the ownership format of the selection's copies (Physical / Digital / ROM).
    /// Only a game with exactly one non-subscription single copy is changed; games with
    /// several copies are skipped and counted in the banner. One transaction, one undo step.
    func changeCopyFormat(ids: Set<Int64>, to format: ProductFormat) async {
        guard !ids.isEmpty else { return }
        do {
            let result = try await store.changeCopyFormat(gameIDs: Array(ids), to: format)
            let reapply = result.reverts.map {
                CopyFormatChange(productID: $0.productID, previousFormat: format)
            }
            registerCopyFormatUndo(restore: result.reverts, reapply: reapply)
            vm?.showBanner(Self.copyFormatBanner(result, format: format), kind: .info)
        } catch {
            vm?.showBanner("Couldn't change the copy format.", kind: .error)
        }
    }

    /// "12 changed to Digital · 3 skipped (several copies)".
    nonisolated static func copyFormatBanner(_ result: ChangeCopyFormatResult, format: ProductFormat) -> String {
        var bits = ["\(result.changed) changed to \(format.label)"]
        if result.skipped > 0 { bits.append("\(result.skipped) skipped (several copies)") }
        return bits.joined(separator: " · ")
    }

    private func registerCopyFormatUndo(restore: [CopyFormatChange], reapply: [CopyFormatChange]) {
        guard let undo = vm?.undoManager, !restore.isEmpty else { return }
        undo.registerUndo(withTarget: self) { target in
            Task { await target.performCopyFormatUndo(restore: restore, reapply: reapply) }
        }
        undo.setActionName("Change Copy Format")
    }

    /// Apply the restore side and register the swapped step (so undo↔redo alternate).
    /// `internal` so a test can drive the inverse directly (`UndoManager.undo()` deadlocks
    /// headless).
    func performCopyFormatUndo(restore: [CopyFormatChange], reapply: [CopyFormatChange]) async {
        try? await store.restoreCopyFormats(restore)
        registerCopyFormatUndo(restore: reapply, reapply: restore)
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

    /// The sticky format for the ask-once batch sheet (persisted; injectable for tests).
    var batchOwnershipPreferences: any BatchOwnershipPreferenceStoring
        = UserDefaultsBatchOwnershipPreferences()

    /// Mark game(s) owned. A single game keeps today's behaviour (multi-platform →
    /// picker; single-platform → immediate). Marking **several** games opens the
    /// ask-once batch sheet (PLAN §8) instead of silently adding a physical copy
    /// on each primary platform.
    private func addOwnership(ids: Set<Int64>) async {
        guard let vm else { return }
        // Single game.
        if ids.count == 1, let id = ids.first,
           let summary = vm.games.first(where: { $0.id == id }) {
            if summary.owned { vm.showBanner("Already owned.", kind: .info); return }
            if summary.platformIDs.count > 1 {
                await requestOwnershipCopy(gameID: id, title: summary.title, platforms: summary.platformIDs)
            } else if let platform = summary.platformIDs.first {
                do { _ = try await store.addCopy(gameID: id, platformID: platform); notifyLibraryChanged() }
                catch { vm.showBanner("Couldn't add a copy.", kind: .error) }
            } else {
                vm.showBanner("No platform to add a copy on.", kind: .warning)
            }
            return
        }

        // Several games → ask once for the whole batch.
        let games = ids.compactMap { id in vm.games.first { $0.id == id } }
        guard BatchOwnershipModel.hasPendingGames(games) else {
            // Nothing to add (all already owned / none has a platform).
            let owned = games.filter(\.owned).count
            vm.showBanner(owned > 0 ? "^[\(owned) game](inflect: true) already owned — unchanged."
                                    : "Nothing to mark owned.", kind: .info)
            return
        }
        let allPlatforms = (try? await store.allPlatforms()) ?? PlatformLabels.all
        vm.batchOwnershipRequest = BatchOwnershipModel(
            games: games,
            allPlatforms: allPlatforms.isEmpty ? PlatformLabels.all : allPlatforms,
            preferences: batchOwnershipPreferences,
            onConfirm: { [weak self] specs in
                Task { await self?.performBatchOwn(specs) }
            }
        )
    }

    /// Write a confirmed "Mark Owned" batch in one transaction. No undo — matches
    /// today's single Mark Owned (which registers none).
    private func performBatchOwn(_ specs: [BatchCopySpec]) async {
        guard !specs.isEmpty else { return }
        do {
            _ = try await store.addCopies(specs)
            notifyLibraryChanged()
            vm?.showBanner("Marked ^[\(specs.count) game](inflect: true) owned.", kind: .info)
        } catch {
            vm?.showBanner("Couldn't add the copies.", kind: .error)
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
    ///
    /// Bulk un-own is intentionally **not** supported (owner: out of scope this
    /// wave): removing many games' copies safely means per-game copy pickers and
    /// orphan confirmations, which can't be fully tested headless. A multi-selection
    /// ⇧O-off shows a banner instead of half-removing copies.
    private func removeOwnership(ids: Set<Int64>) async {
        guard let vm else { return }
        if ids.count > 1 {
            vm.showBanner("Un-own one game at a time — select a single game, then ⇧O.", kind: .info)
            return
        }
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
        vm.copyRemovalRequest = CopyRemovalRequest(
            title: detail.title,
            copies: choices,
            perform: { [weak self] productIDs in
                Task { await self?.performCopyRemoval(productIDs, gameTitle: detail.title) }
            }
        )
    }

    private func performCopyRemoval(_ productIDs: [Int64], gameTitle: String) async {
        guard !productIDs.isEmpty else { return }
        do {
            let (outcome, undo) = try await store.removeProductsCapturingUndo(productIDs)
            switch outcome {
            case .ok:
                if let undo { registerCopyRemovalUndo(undo, productIDs: productIDs, gameTitle: gameTitle) }
            case .wouldOrphan:
                // Removing the last copy would orphan the game — confirm, then remove + delete
                // (still one undo step that restores the product AND the deleted game).
                confirmOrphan(
                    title: "\u{201C}\(gameTitle)\u{201D} is neither owned nor played any more — delete it from the library?",
                    onConfirm: { [weak self] in
                        Task {
                            guard let self else { return }
                            if let (_, undo) = try? await self.store.removeProductsCapturingUndo(
                                productIDs, confirmOrphanDelete: true), let undo {
                                self.registerCopyRemovalUndo(undo, productIDs: productIDs, gameTitle: gameTitle)
                            }
                        }
                    }
                )
            }
        } catch {
            vm?.showBanner("Couldn't remove the copy.", kind: .error)
        }
    }

    /// Register the undo for a copy removal: restore the reconcile snapshot (product rows,
    /// `product_games`, any orphan-deleted game) and register re-removal as the redo.
    private func registerCopyRemovalUndo(_ undo: ReconcileUndo, productIDs: [Int64], gameTitle: String) {
        guard let um = vm?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.undoCopyRemoval(undo, productIDs: productIDs, gameTitle: gameTitle) }
        }
        um.setActionName(undo.actionName)
    }

    /// Restore a copy-removal snapshot (undo) and register re-removal as redo. `internal` so a
    /// test drives it directly (`UndoManager.undo()` hangs headless).
    func undoCopyRemoval(_ undo: ReconcileUndo, productIDs: [Int64], gameTitle: String) async {
        do { try await store.restoreReconcile(undo) }
        catch { vm?.showBanner("Couldn't undo.", kind: .error); return }
        guard let um = vm?.undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.performCopyRemoval(productIDs, gameTitle: gameTitle) }
        }
        um.setActionName(undo.actionName)
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
        // Name every affected game (PLAN §8 — all-or-nothing ownership lists them).
        if !copy.memberTitles.isEmpty { return copy.memberTitles }
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
