import Foundation
import Observation
import SwiftUI

/// **Ranking ▸ Reset All Duels… / Reset Duels in Tier…** (PLAN §7, owner request
/// 2026-09-25). An explicit owner action — never automatic (PLAN §4 inv. 5): it names the
/// real counts in a confirmation, writes a `before-duel-reset-<stamp>.sqlite` snapshot first
/// (live library only), runs ``RankingStore/resetDuels(_:snapshotDirectory:)`` in one
/// transaction and registers ONE undo step ("Reset All Duels") whose inverse restores the
/// rank keys and comparison rows exactly.
@MainActor
@Observable
final class DuelResetPresenter {
    /// A pending confirmation (drives the alert).
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        var scope: RankingStore.DuelResetScope
        var title: String
        var message: String
        var confirmTitle: String
    }

    private(set) var confirmation: Confirmation?
    /// The last failure, in words (also shown as an error banner). nil after a success.
    private(set) var lastError: String?
    /// Bumped after every reset / undo so open ranking screens reload.
    private(set) var resetGeneration = 0

    @ObservationIgnored private let ranking: RankingStore
    /// Where the pre-reset snapshot goes; nil (sample / seeded / test runs) ⇒ no snapshot,
    /// never the owner's real backups folder.
    @ObservationIgnored private let snapshotDirectory: (@Sendable () throws -> URL)?
    /// The library window's view model — its undo manager, tier letters and banner.
    @ObservationIgnored weak var library: LibraryViewModel?
    /// Test seam: an undo manager used when there is no library view model.
    @ObservationIgnored var undoManagerOverride: UndoManager?

    init(ranking: RankingStore, snapshotDirectory: (@Sendable () throws -> URL)?) {
        self.ranking = ranking
        self.snapshotDirectory = snapshotDirectory
    }

    private var undoManager: UndoManager? { undoManagerOverride ?? library?.undoManager }

    private func letter(for tierID: Int64) -> String {
        library?.tiers.first { $0.id == tierID }?.letter ?? "?"
    }

    // MARK: - Confirmation

    /// Load the real counts for `scope` and raise the confirmation (or say there is nothing
    /// to reset).
    func request(_ scope: RankingStore.DuelResetScope) async {
        do {
            let counts = try await ranking.duelResetCounts(scope)
            let tierLetter: String? = if case .tier(let id) = scope { letter(for: id) } else { nil }
            guard !counts.isEmpty else {
                library?.showBanner(Self.nothingToReset(tierLetter: tierLetter), kind: .info)
                return
            }
            let text = Self.confirmationText(counts, tierLetter: tierLetter)
            confirmation = Confirmation(scope: scope, title: text.title, message: text.message,
                                        confirmTitle: text.confirm)
        } catch {
            library?.showBanner("Couldn't read the duel counts.", kind: .error)
        }
    }

    func cancel() { confirmation = nil }

    /// The confirmed action. Takes the confirmation **value** the alert presented, never the
    /// stored ``confirmation``: SwiftUI dismisses the alert (its `isPresented` setter →
    /// ``cancel()`` clears ``confirmation``) before the button's `Task` runs, so re-reading the
    /// stored value here found nil and the reset silently never ran (owner bug, wave 22).
    func confirm(_ pending: Confirmation) async {
        confirmation = nil
        await perform(pending.scope)
    }

    // MARK: - Perform / undo (internal so tests drive them directly)

    @discardableResult
    func perform(_ scope: RankingStore.DuelResetScope) async -> RankingStore.DuelResetUndo? {
        do {
            let dir: URL?
            do {
                dir = try snapshotDirectory?()
            } catch {
                throw RankingStore.DuelResetError.snapshotFailed(
                    "no backups folder: \(error.localizedDescription)")
            }
            let undo = try await ranking.resetDuels(scope, snapshotDirectory: dir)
            lastError = nil
            resetGeneration &+= 1
            registerUndo(undo)
            let placed = undo.placements.count, duels = undo.comparisons.count
            library?.showBanner(
                "Forgot ^[\(duels) duel](inflect: true) and un-placed ^[\(placed) game](inflect: true) — "
                    + "tiers kept." + (undo.snapshotURL != nil ? " A snapshot was saved first." : ""),
                kind: .info)
            return undo
        } catch {
            let message = Self.failureText(error)
            lastError = message
            library?.showBanner(message, kind: .error)
            return nil
        }
    }

    /// The exact inverse (restores rank keys, comparison rows, duel state), and registers
    /// the redo (which re-runs the reset — with a fresh snapshot).
    func performUndo(_ undo: RankingStore.DuelResetUndo) async {
        do {
            try await ranking.undoDuelReset(undo)
            resetGeneration &+= 1
            guard let um = undoManager else { return }
            um.registerUndo(withTarget: self) { target in
                Task { @MainActor in await target.perform(undo.scope) }
            }
            um.setActionName(actionName(undo.scope))
        } catch {
            library?.showBanner("Couldn't undo the duel reset: \(error).", kind: .error)
        }
    }

    private func registerUndo(_ undo: RankingStore.DuelResetUndo) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { target in
            Task { @MainActor in await target.performUndo(undo) }
        }
        um.setActionName(actionName(undo.scope))
    }

    func actionName(_ scope: RankingStore.DuelResetScope) -> String {
        switch scope {
        case .all: return Self.resetAllTitle
        case .tier(let id): return "Reset Duels in Tier \(letter(for: id))"
        }
    }

    // MARK: - Copy (pure, tested)

    nonisolated static let resetAllTitle = "Reset All Duels"

    nonisolated static func confirmationText(
        _ counts: RankingStore.DuelResetCounts, tierLetter: String?
    ) -> (title: String, message: String, confirm: String) {
        let duels = counts.comparisons == 1 ? "1 duel" : "\(counts.comparisons) duels"
        let games = counts.placedGames == 1 ? "1 game" : "\(counts.placedGames) games"
        let place = tierLetter.map { " in tier \($0)" } ?? ""
        let title = "Forget \(duels) and un-place \(games)\(place)? Tiers are kept."
        let message = "Every game stays in its tier, unplaced — The Top shows tier midpoints and "
            + "Duel offers to place them again. A snapshot of your library is saved first, and "
            + "Edit ▸ Undo brings everything back."
        return (title, message, tierLetter == nil ? "Reset All Duels" : "Reset Tier \(tierLetter!)")
    }

    /// The error banner: says nothing changed AND why (never a silent no-op).
    nonisolated static func failureText(_ error: any Error) -> String {
        let reason: String
        if let reset = error as? RankingStore.DuelResetError {
            reason = reset.description
        } else {
            reason = String(describing: error)
        }
        return "Couldn't reset the duels — nothing was changed: \(reason)."
    }

    nonisolated static func nothingToReset(tierLetter: String?) -> String {
        tierLetter.map { "No duels to reset in tier \($0)." } ?? "No duels to reset."
    }
}

// MARK: - Alert

extension View {
    /// The Reset Duels confirmation alert, driven by the presenter.
    func duelResetConfirmation(_ presenter: DuelResetPresenter) -> some View {
        modifier(DuelResetAlertModifier(presenter: presenter))
    }
}

private struct DuelResetAlertModifier: ViewModifier {
    @Bindable var presenter: DuelResetPresenter

    func body(content: Content) -> some View {
        content.alert(
            presenter.confirmation?.title ?? DuelResetPresenter.resetAllTitle,
            isPresented: Binding(get: { presenter.confirmation != nil },
                                 set: { if !$0 { presenter.cancel() } }),
            presenting: presenter.confirmation
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) { Task { await presenter.confirm(pending) } }
            Button("Cancel", role: .cancel) { presenter.cancel() }
        } message: { pending in
            Text(pending.message)
        }
    }
}

// MARK: - Menu bar

/// **Ranking ▸ Reset All Duels… / Reset Duels in Tier ▸ S…F** (PLAN §7). PURE builder; the
/// actions switch to the Duel screen (where the confirmation is shown) and request it.
struct RankingCommands: Commands {
    let presenter: DuelResetPresenter?
    @FocusedValue(\.library) private var library

    var body: some Commands {
        CommandMenu("Ranking") {
            Button("\(DuelResetPresenter.resetAllTitle)…") { request(.all) }
                .disabled(presenter == nil || library == nil)
            Menu("Reset Duels in Tier") {
                ForEach(library?.tiers ?? []) { tier in
                    Button("\(tier.letter) · \(tier.label)…") { request(.tier(tier.id)) }
                }
            }
            .disabled(presenter == nil || library == nil || (library?.tiers.isEmpty ?? true))
        }
    }

    private func request(_ scope: RankingStore.DuelResetScope) {
        guard let presenter else { return }
        library?.select(.duel)
        Task { await presenter.request(scope) }
    }
}
