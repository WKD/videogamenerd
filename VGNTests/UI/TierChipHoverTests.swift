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

    // Owner request 2026-09-19: the badge tooltip also carries the derived score.

    // The exact "9.4" / "~8.5" / locale formatting is covered in DerivedScoreTests;
    // here we assert hoverText *composes* "<base> · <formatted>" (locale-robust).

    @Test func appendsAnExactScore() {
        let score = DerivedScoreValue(value: 9.42, isApproximate: false)
        #expect(TierChip.hoverText(letter: "S", label: nil, labels: labels, score: score) ==
                "S — Masterpiece · \(score.formatted())")
    }

    @Test func appendsAnApproximateScoreWithTilde() {
        let score = DerivedScoreValue(value: 8.5, isApproximate: true)
        #expect(score.formatted().hasPrefix("~"))
        #expect(TierChip.hoverText(letter: "A", label: nil, labels: labels, score: score) ==
                "A — Excellent · \(score.formatted())")
    }

    @Test func labelOnlyWhenNoScoreGiven() {
        #expect(TierChip.hoverText(letter: "S", label: nil, labels: labels, score: nil) == "S — Masterpiece")
    }

    @Test func scoreStillAppendsWhenOnlyTheLetterIsKnown() {
        let score = DerivedScoreValue(value: 3.0, isApproximate: false)
        #expect(TierChip.hoverText(letter: "Z", label: nil, labels: labels, score: score) ==
                "Tier Z · \(score.formatted())")
    }
}
