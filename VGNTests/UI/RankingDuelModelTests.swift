import Testing
@testable import VGN

/// DuelModel state-machine tests, driven against ``ScriptedRankingBackend`` (no
/// database). Covers prompt → answer → next, skip, undo, border accept/dismiss,
/// the drained empty state, the completion toast, and a prompt vanishing
/// mid-flight (PLAN §7).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RankingDuelModelTests {

    private func placement(_ c: Int64, _ o: Int64, made: Int = 0, total: Int = 4) -> DuelPrompt {
        DuelPrompt(kind: .placement, candidate: c, opponent: o,
                   candidateTier: 1, opponentTier: 1, comparisonsMade: made, estimatedTotal: total)
    }

    private func backend(_ prompt: DuelPrompt?) -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let s = TierInfo.defaults[0]
        b.details[1] = .rankingSample(id: 1, title: "One", tier: s)
        b.details[2] = .rankingSample(id: 2, title: "Two", tier: s)
        b.details[3] = .rankingSample(id: 3, title: "Three", tier: s)
        b.details[4] = .rankingSample(id: 4, title: "Four", tier: s)
        b.currentPrompt = prompt
        return b
    }

    @Test func refreshBuildsDisplayFromPrompt() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        #expect(m.display?.prompt.candidate == 1)
        #expect(m.display?.candidate.title == "One")
        #expect(m.display?.opponent.title == "Two")
        #expect(m.isDrained == false)
    }

    @Test func answerRecordsWinnerAndAdvances() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()

        b.nextOutcome = .placed(gameID: 1, complete: false)
        b.currentPrompt = placement(3, 4)
        await m.choose(winner: 1)

        #expect(b.answered == [1])
        #expect(m.lastWinnerID == 1)
        #expect(m.display?.prompt.candidate == 3)
    }

    @Test func pickHelpersChooseCorrectSide() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        b.nextOutcome = .placed(gameID: 2, complete: false)
        await m.pickOpponent()
        #expect(b.answered == [2])
    }

    @Test func skipDefersWithoutAnswering() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        b.currentPrompt = placement(3, 4)
        await m.skip()
        #expect(b.skipCount == 1)
        #expect(b.answered.isEmpty)
        #expect(m.display?.prompt.candidate == 3)
        #expect(m.lastWinnerID == nil)
    }

    @Test func undoCallsStoreAndRefreshes() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        await m.undo()
        #expect(b.undoCount == 1)
    }

    @Test func borderAnswerHoldsSuggestionThenAccept() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()

        let suggestion = BorderSuggestion(game: 1, fromTier: 2, toTier: 1, kind: .promote)
        b.nextOutcome = .border(suggestion)
        await m.choose(winner: 1)
        #expect(m.borderSuggestion == suggestion)
        #expect(m.display != nil)            // still on the duel until decided

        b.currentPrompt = nil
        await m.acceptBorder()
        #expect(b.accepted == [suggestion])
        #expect(m.borderSuggestion == nil)
        #expect(m.isDrained)
    }

    @Test func borderDismissDismissesAndAdvances() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        let suggestion = BorderSuggestion(game: 2, fromTier: 1, toTier: 2, kind: .demote)
        b.nextOutcome = .border(suggestion)
        await m.choose(winner: 1)
        #expect(m.borderSuggestion != nil)

        b.currentPrompt = placement(3, 4)
        await m.dismissBorder()
        #expect(b.dismissed == [suggestion])
        #expect(m.borderSuggestion == nil)
        #expect(m.display?.prompt.candidate == 3)
    }

    @Test func borderWithoutSuggestionJustAdvances() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        b.nextOutcome = .border(nil)
        b.currentPrompt = placement(3, 4)
        await m.choose(winner: 1)
        #expect(m.borderSuggestion == nil)
        #expect(m.display?.prompt.candidate == 3)
    }

    @Test func placementCompletionShowsToastWithPosition() async {
        let b = backend(placement(1, 2))
        let s = TierInfo.defaults[0]
        b.board = [TierBoardRow(tier: s,
                                placed: [GameSummary(id: 1, title: "One", tierID: s.id, rankKey: 1000, played: true)],
                                unplaced: [])]
        let m = DuelModel(backend: b)
        await m.refresh()

        b.nextOutcome = .placed(gameID: 1, complete: true)
        b.currentPrompt = nil
        await m.choose(winner: 1)
        #expect(m.toast?.text == "One → #1 in S")
        #expect(m.isDrained)
    }

    @Test func drainedQueueGivesEmptyState() async {
        let b = backend(nil)
        b.stats = ScriptedRankingBackend.sampleStats()
        b.unranked = [GameSummary(id: 9, title: "Backlog", played: true)]
        let m = DuelModel(backend: b)
        await m.refresh()
        #expect(m.display == nil)
        #expect(m.isDrained)
        #expect(m.unrankedCount == 1)
    }

    @Test func promptVanishingMidFlightDrainsGracefully() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        #expect(m.display != nil)

        b.currentPrompt = nil            // game deleted / un-played underneath us
        await m.refresh()
        #expect(m.display == nil)
        #expect(m.isDrained)
    }

    @Test func missingSideDrainsRatherThanCrashing() async {
        let b = backend(placement(1, 99))   // 99 has no detail
        let m = DuelModel(backend: b)
        await m.refresh()
        #expect(m.display == nil)
        #expect(m.isDrained)
    }

    @Test func undoClearsToastAndBorder() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()
        b.nextOutcome = .border(BorderSuggestion(game: 1, fromTier: 2, toTier: 1, kind: .promote))
        await m.choose(winner: 1)
        #expect(m.borderSuggestion != nil)

        await m.undo()
        #expect(m.borderSuggestion == nil)
        #expect(b.undoCount == 1)
    }

    // MARK: Key routing through the model

    @Test func handleRoutesKeysToActions() async {
        let b = backend(placement(1, 2))
        let m = DuelModel(backend: b)
        await m.refresh()

        await m.handle(.peek)
        #expect(m.isPeeking)

        b.nextOutcome = .placed(gameID: 1, complete: false)
        await m.handle(.left)
        #expect(b.answered == [1])
    }
}
