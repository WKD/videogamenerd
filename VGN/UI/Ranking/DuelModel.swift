import Observation
import SwiftUI

/// A transient, non-blocking toast after a placement completes (PLAN §7 —
/// "Bloodborne → #4 in A" with Undo).
struct DuelToast: Equatable, Identifiable {
    let id = UUID()
    var text: String
}

/// All Duel-screen logic (PLAN §7). The view is a thin shell that binds to this;
/// every state transition — answer, skip, undo, border accept/dismiss, the drain
/// to the empty state — lives here and is unit-tested against a fake
/// ``RankingBackend`` with no database.
@MainActor
@Observable
final class DuelModel {
    // MARK: Presented state
    /// The current duel resolved for display, or `nil` when the queue is drained.
    private(set) var display: DuelDisplay?
    /// A border suggestion awaiting Accept/Dismiss — its card takes over the screen.
    private(set) var borderSuggestion: BorderSuggestion?
    /// Completion toast ("→ #4 in A"), auto-dismissed.
    private(set) var toast: DuelToast?
    /// Live "n games left to place" (PLAN §7).
    private(set) var queueCount = 0
    /// Placed/unplaced per tier for the empty-state summary.
    private(set) var stats = RankingStats(perTier: [])
    /// Unranked *played* games — the pointer to Triage in the empty state.
    private(set) var unrankedCount = 0
    /// Preference cycles (A>B>C>A) — the "n disputes" chip.
    private(set) var disputes: [Consistency.Dispute] = []
    /// Titles for the games caught in disputes (for the sheet).
    private(set) var disputeTitles: [Int64: String] = [:]
    /// The winner of the last answer, for a brief acknowledgement flourish.
    private(set) var lastWinnerID: Int64?
    /// True while the first prompt is being resolved (spinner vs empty state).
    private(set) var isLoading = true
    /// Whether the details popover ("peek") is open.
    var isPeeking = false

    /// True once the queue is drained (no prompt, not loading) → empty state.
    var isDrained: Bool { display == nil && borderSuggestion == nil && !isLoading }

    // MARK: Seams
    private let backend: any RankingBackend
    private var tierByID: [Int64: TierInfo] = [:]
    private var liveTasks: [Task<Void, Never>] = []
    private var toastTask: Task<Void, Never>?

    init(backend: any RankingBackend) {
        self.backend = backend
    }

    // MARK: Lifecycle

    /// Load tiers, resolve the first prompt, and subscribe to live counts. Safe to
    /// call again (idempotent) when the view reappears — the session is resumable
    /// because the store persists it (PLAN §7), so we simply re-ask `currentDuel`.
    func start() async {
        if tierByID.isEmpty { await loadTiers() }
        await refresh()
        subscribeLive()
    }

    func stop() {
        for task in liveTasks { task.cancel() }
        liveTasks.removeAll()
        toastTask?.cancel()
    }

    private func loadTiers() async {
        let tiers = (try? await backend.tiers()) ?? []
        tierByID = Dictionary(uniqueKeysWithValues: tiers.map { ($0.id, $0) })
    }

    private func subscribeLive() {
        guard liveTasks.isEmpty else { return }
        liveTasks.append(Task { [backend] in
            for await count in backend.duelQueueCountStream() {
                self.queueCount = count
            }
        })
        liveTasks.append(Task { [backend] in
            for await stats in backend.rankingStatsStream() {
                self.stats = stats
            }
        })
        liveTasks.append(Task { [backend] in
            for await games in backend.unrankedGamesStream() {
                self.unrankedCount = games.count
                // A game deleted / un-played out from under us may have drained the
                // queue; re-resolve when nothing is currently shown.
                if self.display == nil, self.borderSuggestion == nil {
                    await self.refresh()
                }
            }
        })
    }

    // MARK: Resolving the next prompt

    /// Ask the store what to show next and build its display. Robust to the game
    /// vanishing (deleted mid-flight) — a missing detail just drains to empty.
    func refresh() async {
        await loadDisputes()
        do {
            guard let prompt = try await backend.currentDuel() else {
                display = nil
                isLoading = false
                await refreshEmptyStateFacts()
                return
            }
            guard let display = try await buildDisplay(for: prompt) else {
                // A side is gone — advance past it rather than crash.
                self.display = nil
                isLoading = false
                await refreshEmptyStateFacts()
                return
            }
            self.display = display
            isLoading = false
        } catch {
            display = nil
            isLoading = false
        }
    }

    private func buildDisplay(for prompt: DuelPrompt) async throws -> DuelDisplay? {
        async let candidate = backend.gameDetail(id: prompt.candidate)
        async let opponent = backend.gameDetail(id: prompt.opponent)
        guard let c = try await candidate, let o = try await opponent else { return nil }
        return DuelDisplay(prompt: prompt, candidate: DuelSide(detail: c), opponent: DuelSide(detail: o))
    }

    private func refreshEmptyStateFacts() async {
        stats = (try? await backend.rankingStatsOnce()) ?? stats
        unrankedCount = (try? await backend.unrankedPlayedGames().count) ?? unrankedCount
    }

    /// Refresh the disputes chip + the titles its sheet needs (cheap at this scale).
    private func loadDisputes() async {
        guard let found = try? await backend.contradictions() else { return }
        disputes = found
        var titles = disputeTitles
        for id in Set(found.flatMap(\.games)) where titles[id] == nil {
            if let detail = try? await backend.gameDetail(id: id) { titles[id] = detail.title }
        }
        disputeTitles = titles
    }

    /// "Settle" a dispute: enqueue the cycle's consecutive pairs so the Duel re-asks
    /// exactly those comparisons (PLAN §7 follow-up — "duel exactly this pair"). The
    /// fresh answers break the contradiction, in place, without re-placing the games.
    func settle(_ dispute: Consistency.Dispute) async {
        let cycle = dispute.cycle
        if cycle.count >= 2 {
            for i in 0..<cycle.count {
                let a = cycle[i], b = cycle[(i + 1) % cycle.count]
                try? await backend.enqueuePair(a, b)
            }
        }
        await refresh()
    }

    // MARK: Answering (← / →)

    /// Answer the current duel by naming the winning game (PLAN §7).
    func choose(winner: Int64) async {
        guard display != nil, borderSuggestion == nil else { return }
        lastWinnerID = winner
        let outcome = (try? await backend.answer(winner: winner)) ?? .none
        switch outcome {
        case let .placed(gameID, complete):
            if complete { await showPlacementToast(gameID: gameID) }
            await refresh()
        case .refined:
            await refresh()
        case let .border(suggestion):
            if let suggestion {
                borderSuggestion = suggestion   // hold; wait for Accept/Dismiss
            } else {
                await refresh()
            }
        case .none:
            await refresh()
        }
    }

    /// Convenience for the view's ←/→ keys.
    func pickCandidate() async { if let id = display?.candidate.id { await choose(winner: id) } }
    func pickOpponent() async { if let id = display?.opponent.id { await choose(winner: id) } }

    // MARK: Skip (↓) — no animation, no toast

    func skip() async {
        guard display != nil, borderSuggestion == nil else { return }
        lastWinnerID = nil
        try? await backend.skip()
        await refresh()
    }

    // MARK: Undo (⌘Z)

    func undo() async {
        clearToast()
        borderSuggestion = nil
        lastWinnerID = nil
        _ = try? await backend.undo()
        await refresh()
    }

    // MARK: Border suggestion (↩ / esc)

    func acceptBorder() async {
        guard let suggestion = borderSuggestion else { return }
        try? await backend.acceptBorderSuggestion(suggestion)
        borderSuggestion = nil
        await refresh()
    }

    func dismissBorder() async {
        guard let suggestion = borderSuggestion else { return }
        try? await backend.dismissBorderSuggestion(suggestion)
        borderSuggestion = nil
        await refresh()
    }

    // MARK: Key routing

    /// Dispatch a routed key intent (PLAN §7 key map).
    func handle(_ key: DuelKeyInput) async {
        switch DuelKeyRouter.intent(for: key, showingBorderSuggestion: borderSuggestion != nil) {
        case .pickCandidate: await pickCandidate()
        case .pickOpponent: await pickOpponent()
        case .skip: await skip()
        case .undo: await undo()
        case .togglePeek: isPeeking.toggle()
        case .acceptBorder: await acceptBorder()
        case .dismissBorder: await dismissBorder()
        case .ignored: break
        }
    }

    // MARK: Toast

    private func showPlacementToast(gameID: Int64) async {
        guard let placement = await placement(of: gameID) else { return }
        setToast(DuelToast(text: "\(placement.title) → #\(placement.position) in \(placement.letter)"))
    }

    /// Where a just-placed game landed, from the live tier board.
    private func placement(of gameID: Int64) async -> (title: String, letter: String, position: Int)? {
        guard let board = try? await backend.tierBoardOnce() else { return nil }
        for row in board {
            if let idx = row.placed.firstIndex(where: { $0.id == gameID }) {
                return (row.placed[idx].title, row.tier.letter, idx + 1)
            }
        }
        return nil
    }

    private func setToast(_ toast: DuelToast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self.toast = nil }
        }
    }

    func clearToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Undo straight from the toast's action button.
    func undoFromToast() async {
        await undo()
    }

    // MARK: Empty-state helpers

    /// Tier lookup for chips / summaries.
    func tier(_ id: Int64) -> TierInfo? { tierByID[id] }
}
