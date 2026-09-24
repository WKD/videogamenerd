import Observation
import SwiftUI

/// All Triage logic (PLAN §7 — bulk-tier played games that have no tier yet:
/// one big cover, press `S A B C D F` to tier, `0`/`space` to skip, `←` back).
/// `1`/`2`/`3` rate the current game **Holds Up / Of Its Time / Too Archaic** (PLAN §7b) —
/// a separate mark, so it does not advance: rate, then tier.
/// The view is a thin shell. Unit-tested against a fake ``RankingBackend``.
///
/// Note: Triage tiers through `RankingStore.setTier`, which is a plain write and
/// **not** in the duel-undo history — so "back" restores a game by *clearing its
/// tier* (`setTier(nil)`), the exact inverse of the unranked → tiered step, rather
/// than calling `undo()`.
@MainActor
@Observable
final class TriageModel {
    /// One recorded step, so `←` can restore it.
    private struct Step { var game: GameSummary; var index: Int; var tierID: Int64 }

    private(set) var tiers: [TierInfo] = []
    /// Games still to tier, current at `cursor`.
    private(set) var pending: [GameSummary] = []
    private(set) var cursor = 0
    /// How many games have been tiered this session.
    private(set) var tieredCount = 0
    /// Counts per tier id (end-state summary).
    private(set) var perTierCounts: [Int64: Int] = [:]
    private(set) var isLoading = true
    /// Brief highlight of the last tier pressed.
    private(set) var highlightedTier: Int64?
    /// A not-owned game the user un-played, awaiting an explicit "Remove from
    /// library" decision (PLAN §7 follow-up — never a surprise delete).
    private(set) var removalPrompt: GameSummary?

    private var history: [Step] = []
    private let backend: any RankingBackend
    private var highlightTask: Task<Void, Never>?

    init(backend: any RankingBackend) {
        self.backend = backend
    }

    // MARK: Derived

    var current: GameSummary? { cursor < pending.count ? pending[cursor] : nil }
    /// The next game (for cover preloading).
    var next: GameSummary? { cursor + 1 < pending.count ? pending[cursor + 1] : nil }
    var isDone: Bool { !isLoading && pending.isEmpty }
    var total: Int { tieredCount + pending.count }
    var progressText: String {
        guard total > 0 else { return "0 of 0" }
        return "\(min(tieredCount + 1, total)) of \(total)"
    }
    var canGoBack: Bool { !history.isEmpty }

    func tier(_ id: Int64) -> TierInfo? { tiers.first { $0.id == id } }

    // MARK: Lifecycle

    func start() async {
        tiers = (try? await backend.tiers()) ?? []
        pending = (try? await backend.unrankedPlayedGames()) ?? []
        cursor = 0
        isLoading = false
    }

    // MARK: Actions

    /// Tier the current game (`S A B C D F`, or a legend click).
    func tierCurrent(_ tierID: Int64) async {
        guard let game = current else { return }
        _ = try? await backend.setTier([game.id], tierID: tierID)
        history.append(Step(game: game, index: cursor, tierID: tierID))
        perTierCounts[tierID, default: 0] += 1
        tieredCount += 1
        pending.remove(at: cursor)
        if cursor > pending.count { cursor = pending.count }
        flashHighlight(tierID)
    }

    /// Map a typed letter to a tier and apply it (returns false if not a tier key).
    @discardableResult
    func tierCurrent(letter: String) async -> Bool {
        guard let match = tiers.first(where: { $0.letter.caseInsensitiveCompare(letter) == .orderedSame })
        else { return false }
        await tierCurrent(match.id)
        return true
    }

    /// Skip the current game to the end of the queue (`0` / `space`). No write.
    func skip() {
        guard cursor < pending.count, pending.count > 1 else { return }
        let game = pending.remove(at: cursor)
        pending.append(game)
        if cursor >= pending.count { cursor = 0 }
    }

    /// Undo the last tiering (`←`): clear the game's tier and restore it in place.
    func back() async {
        guard let step = history.popLast() else { return }
        _ = try? await backend.setTier([step.game.id], tierID: nil)
        perTierCounts[step.tierID, default: 1] -= 1
        if perTierCounts[step.tierID] == 0 { perTierCounts[step.tierID] = nil }
        tieredCount = max(0, tieredCount - 1)
        let insertAt = min(step.index, pending.count)
        pending.insert(step.game, at: insertAt)
        cursor = insertAt
    }

    // MARK: "Holds up today?" (`1`/`2`/`3` — PLAN §7b)

    /// The Triage key for each value (`1` Holds Up, `2` Of Its Time, `3` Too Archaic). Free
    /// keys: letters tier, `0`/space skip, `U` un-plays.
    static let holdsUpKeys: [Character: HoldsUp] = ["1": .holdsUp, "2": .ofItsTime, "3": .tooArchaic]

    /// Rate the current game (pressing its current value again clears it back to Unrated).
    /// Does NOT advance — the game still needs its tier; the card shows the mark at once.
    func rateCurrent(_ value: HoldsUp) async {
        guard let game = current else { return }
        let newValue: HoldsUp? = game.holdsUp == value ? nil : value
        guard (try? await backend.setHoldsUp(newValue, for: [game.id])) != nil else { return }
        if let index = pending.firstIndex(where: { $0.id == game.id }) {
            pending[index].holdsUp = newValue
        }
    }

    // MARK: Safe un-play (`U`)

    /// `U` — "not actually played" (PLAN §7 follow-up). Owned → the game becomes
    /// Backlog and leaves the queue with no prompt; not owned → a removal prompt is
    /// raised so the user can explicitly delete it (never a surprise modal).
    func unplayCurrent() async {
        guard let game = current else { return }
        switch (try? await backend.markNotPlayed(game.id)) ?? .notFound {
        case .becameBacklog:
            drop(game.id)
        case .notOwned:
            removalPrompt = game
        case .notFound:
            break
        }
    }

    /// Confirm removing a not-owned, un-played game from the library.
    func confirmRemoval() async {
        guard let game = removalPrompt else { return }
        removalPrompt = nil
        try? await backend.deleteGame(game.id)
        drop(game.id)
    }

    /// Cancel the removal — the game stays played and in the queue (un-play was a
    /// no-op for a not-owned game, so nothing to restore).
    func cancelRemoval() { removalPrompt = nil }

    /// Remove a game from the pending queue at wherever it currently is.
    private func drop(_ gameID: Int64) {
        guard let index = pending.firstIndex(where: { $0.id == gameID }) else { return }
        pending.remove(at: index)
        if cursor > pending.count { cursor = pending.count }
    }

    // MARK: Key routing

    /// A typed character → a triage action. Returns whether it was consumed.
    @discardableResult
    func handle(character: Character) async -> Bool {
        let c = Character(character.lowercased())
        if c == "0" || character == " " { skip(); return true }
        if c == "u" { await unplayCurrent(); return true }
        if let value = Self.holdsUpKeys[c] { await rateCurrent(value); return true }
        return await tierCurrent(letter: String(character))
    }

    private func flashHighlight(_ tierID: Int64) {
        highlightedTier = tierID
        highlightTask?.cancel()
        highlightTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { highlightedTier = nil }
        }
    }
}
