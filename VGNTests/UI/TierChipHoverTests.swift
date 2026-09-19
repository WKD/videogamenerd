import Testing
@testable import VGN

/// Hovering a tier letter shows its label (owner request 2026-09-19).
struct TierChipHoverTests {
    private let labels = ["S": "Masterpiece", "A": "Excellent"]

    @Test func usesTheEnvironmentLabelForTheLetter() {
        #expect(TierChip.hoverText(letter: "S", label: nil, labels: labels) == "S — Masterpiece")
        #expect(TierChip.hoverText(letter: "a", label: nil, labels: labels) == "a — Excellent")
    }

    @Test func anExplicitLabelWins() {
        #expect(TierChip.hoverText(letter: "S", label: "God tier", labels: labels) == "S — God tier")
    }

    @Test func fallsBackToTheLetterWhenNoLabelIsKnown() {
        #expect(TierChip.hoverText(letter: "Z", label: nil, labels: labels) == "Tier Z")
        #expect(TierChip.hoverText(letter: "S", label: "  ", labels: [:]) == "Tier S")
    }
}
