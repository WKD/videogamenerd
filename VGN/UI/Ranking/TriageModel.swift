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
    /// A quiet one-line note when the library changed under the current card (wave 23:
    /// the game was tiered / un-played elsewhere, so Triage moved on). Cleared by the next
    /// action.
    private(set) var notice: String?

    private var history: [Step] = []
    private let backend: any RankingBackend
    private var highlightTask: Task<Void, Never>?
    /// Own writes in flight — library emissions are held back meanwhile (they may predate
    /// the write) and replaced by one fresh read once the write settles.
    private var inFlight = 0
    private var emissionWhileInFlight = false

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

    /// Keep the queue in step with the library while Triage is shown (wave 23): follows
    /// the unranked-games DB observation until the calling task is cancelled (the view's
    /// `.task`, so it ends when Triage disappears). No polling.
    func observeLibrary() async {
        for await games in backend.unrankedGamesStream() {
            if Task.isCancelled { break }
            guard !isLoading else { continue }
            if inFlight > 0 {
                emissionWhileInFlight = true
                continue
            }
            reconcile(with: games)
        }
    }

    /// Merge the library's current eligible games (played, untiered) into the queue:
    /// games no longer eligible leave it, newly eligible ones are appended, the rest keep
    /// their order (and pick up fresh data, e.g. a new cover). The current card is never
    /// swapped for another *eligible* game; if the current game itself became ineligible,
    /// Triage advances to the next one with a quiet ``notice``.
    func reconcile(with eligible: [GameSummary]) {
        let freshByID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldCurrent = current

        var kept: [GameSummary] = []
        var keptOldIndex: [Int] = []
        for (index, game) in pending.enumerated() {
            if let fresh = freshByID[game.id] {
                kept.append(fresh)
                keptOldIndex.append(index)
            }
        }
        let known = Set(pending.map(\.id))
        let added = eligible.filter { !known.contains($0.id) }
        let updated = kept + added

        var newCursor = 0
        if let oldCurrent, freshByID[oldCurrent.id] != nil {
            newCursor = updated.firstIndex { $0.id == oldCurrent.id } ?? 0
        } else if let oldCurrent {
            // The current game left the queue: the next surviving game after it, else the
            // first newly eligible one, else wrap to the start.
            if let k = keptOldIndex.firstIndex(where: { $0 > cursor }) {
                newCursor = k
            } else if !added.isEmpty {
                newCursor = kept.count
            }
            notice = "\u{201C}\(oldCurrent.title)\u{201D} changed elsewhere — moved on."
        }
        if pending == updated { return }
        pending = updated
        cursor = updated.isEmpty ? 0 : min(newCursor, updated.count - 1)
    }

    /// Bracket one of our own writes: hold back library emissions, then (if any arrived)
    /// re-read once so the queue reflects the post-write state.
    private func beginWrite() { inFlight += 1; notice = nil }

    private func endWrite() async {
        inFlight -= 1
        guard inFlight == 0, emissionWhileInFlight else { return }
        emissionWhileInFlight = false
        if let fresh = try? await backend.unrankedPlayedGames(), inFlight == 0 {
            reconcile(with: fresh)
        }
    }

    // MARK: Actions

    /// Tier the current game (`S A B C D F`, or a legend click).
    func tierCurrent(_ tierID: Int64) async {
        guard let game = current else { return }
        beginWrite()
        _ = try? await backend.setTier([game.id], tierID: tierID)
        history.append(Step(game: game, index: cursor, tierID: tierID))
        perTierCounts[tierID, default: 0] += 1
        tieredCount += 1
        drop(game.id)
        flashHighlight(tierID)
        await endWrite()
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
        notice = nil
        guard cursor < pending.count, pending.count > 1 else { return }
        let game = pending.remove(at: cursor)
        pending.append(game)
        if cursor >= pending.count { cursor = 0 }
    }

    /// Undo the last tiering (`←`): clear the game's tier and restore it in place.
    func back() async {
        guard let step = history.popLast() else { return }
        beginWrite()
        _ = try? await backend.setTier([step.game.id], tierID: nil)
        perTierCounts[step.tierID, default: 1] -= 1
        if perTierCounts[step.tierID] == 0 { perTierCounts[step.tierID] = nil }
        tieredCount = max(0, tieredCount - 1)
        // It may already be back in the queue (a reconcile appended it) — move, don't
        // duplicate.
        pending.removeAll { $0.id == step.game.id }
        let insertAt = min(step.index, pending.count)
        pending.insert(step.game, at: insertAt)
        cursor = insertAt
        await endWrite()
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
        beginWrite()
        if (try? await backend.setHoldsUp(newValue, for: [game.id])) != nil,
           let index = pending.firstIndex(where: { $0.id == game.id }) {
            pending[index].holdsUp = newValue
        }
        await endWrite()
    }

    // MARK: Safe un-play (`U`)

    /// `U` — "not actually played" (PLAN §7 follow-up). Owned → the game becomes
    /// Backlog and leaves the queue with no prompt; not owned → a removal prompt is
    /// raised so the user can explicitly delete it (never a surprise modal).
    func unplayCurrent() async {
        guard let game = current else { return }
        beginWrite()
        switch (try? await backend.markNotPlayed(game.id)) ?? .notFound {
        case .becameBacklog:
            drop(game.id)
        case .notOwned:
            removalPrompt = game
        case .notFound:
            break
        }
        await endWrite()
    }

    /// Confirm removing a not-owned, un-played game from the library.
    func confirmRemoval() async {
        guard let game = removalPrompt else { return }
        removalPrompt = nil
        beginWrite()
        try? await backend.deleteGame(game.id)
        drop(game.id)
        await endWrite()
    }

    /// Cancel the removal — the game stays played and in the queue (un-play was a
    /// no-op for a not-owned game, so nothing to restore).
    func cancelRemoval() { removalPrompt = nil }

    /// Remove a game from the pending queue at wherever it currently is.
    private func drop(_ gameID: Int64) {
        guard let index = pending.firstIndex(where: { $0.id == gameID }) else { return }
        pending.remove(at: index)
        if index < cursor { cursor -= 1 }
        // Past the end with games left → wrap to the first (skipped games come round again).
        if cursor >= pending.count { cursor = 0 }
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
