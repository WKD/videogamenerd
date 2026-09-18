import Testing
@testable import VGN

/// Pure header/progress copy and the keyboard routing table (PLAN §7, §8). No
/// database, no UI — just the value logic behind the Duel view.
struct RankingPresentationTests {

    private func side(_ id: Int64, _ title: String, tier: String?) -> DuelSide {
        DuelSide(id: id, title: title, tierLetter: tier)
    }

    // MARK: Header per kind

    @Test func placementHeaderReadsInPlainWords() {
        let prompt = DuelPrompt(kind: .placement, candidate: 1, opponent: 2,
                                candidateTier: 2, opponentTier: 2,
                                comparisonsMade: 2, estimatedTotal: 6)
        let h = DuelPresentation.header(prompt: prompt,
                                        candidate: side(1, "Bloodborne", tier: "A"),
                                        opponent: side(2, "Elden Ring", tier: "A"))
        #expect(h.kind == .placement)
        #expect(h.text == "Placing Bloodborne in A · 3 of ~6")
        #expect(h.candidateName == "Bloodborne")
        #expect(h.stepText == "3 of ~6")
        #expect(h.progress == 2.0 / 6.0)
    }

    @Test func refineHeaderNamesTheTier() {
        let prompt = DuelPrompt(kind: .refine, candidate: 1, opponent: 2,
                                candidateTier: 3, opponentTier: 3,
                                comparisonsMade: 0, estimatedTotal: 0)
        let h = DuelPresentation.header(prompt: prompt,
                                        candidate: side(1, "MGS3", tier: "B"),
                                        opponent: side(2, "SH2", tier: "B"))
        #expect(h.kind == .refine)
        #expect(h.text == "Refine · neighbours in B")
        #expect(h.progress == nil)
        #expect(h.stepText == nil)
    }

    @Test func borderHeaderNamesBothTiers() {
        let prompt = DuelPrompt(kind: .border, candidate: 1, opponent: 2,
                                candidateTier: 1, opponentTier: 2,
                                comparisonsMade: 0, estimatedTotal: 0)
        let h = DuelPresentation.header(prompt: prompt,
                                        candidate: side(1, "Bloodborne", tier: "S"),
                                        opponent: side(2, "Sekiro", tier: "A"))
        #expect(h.kind == .border)
        #expect(h.text == "Border duel · bottom of S vs top of A")
    }

    // MARK: Step / progress / queue copy

    @Test func stepClampsToTotalAndProgressCaps() {
        let prompt = DuelPrompt(kind: .placement, candidate: 1, opponent: 2,
                                candidateTier: 1, opponentTier: 1,
                                comparisonsMade: 9, estimatedTotal: 6)
        #expect(DuelPresentation.stepText(prompt) == "6 of ~6")
        #expect(DuelPresentation.progress(prompt) == 1.0)
    }

    @Test func queueTextSingularAndPlural() {
        #expect(DuelPresentation.queueText(1) == "1 game left to place")
        #expect(DuelPresentation.queueText(12) == "12 games left to place")
    }

    // MARK: Key routing table

    @Test func routingWithoutBorderSuggestion() {
        #expect(DuelKeyRouter.intent(for: .left, showingBorderSuggestion: false) == .pickCandidate)
        #expect(DuelKeyRouter.intent(for: .right, showingBorderSuggestion: false) == .pickOpponent)
        #expect(DuelKeyRouter.intent(for: .down, showingBorderSuggestion: false) == .skip)
        #expect(DuelKeyRouter.intent(for: .undo, showingBorderSuggestion: false) == .undo)
        #expect(DuelKeyRouter.intent(for: .peek, showingBorderSuggestion: false) == .togglePeek)
        #expect(DuelKeyRouter.intent(for: .accept, showingBorderSuggestion: false) == .ignored)
        #expect(DuelKeyRouter.intent(for: .dismiss, showingBorderSuggestion: false) == .ignored)
    }

    @Test func routingWithBorderSuggestionSwapsMeaning() {
        #expect(DuelKeyRouter.intent(for: .accept, showingBorderSuggestion: true) == .acceptBorder)
        #expect(DuelKeyRouter.intent(for: .dismiss, showingBorderSuggestion: true) == .dismissBorder)
        #expect(DuelKeyRouter.intent(for: .undo, showingBorderSuggestion: true) == .undo)
        // Picks/skip are suppressed so an answer can't leak past the decision.
        #expect(DuelKeyRouter.intent(for: .left, showingBorderSuggestion: true) == .ignored)
        #expect(DuelKeyRouter.intent(for: .right, showingBorderSuggestion: true) == .ignored)
        #expect(DuelKeyRouter.intent(for: .down, showingBorderSuggestion: true) == .ignored)
    }
}
