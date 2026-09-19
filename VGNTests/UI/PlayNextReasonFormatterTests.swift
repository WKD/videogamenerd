import Foundation
import Testing
@testable import VGN

/// The reason → sentence formatter (PLAN §7b — "the engine emits values; the UI
/// writes the sentences"). Every `PlayNextReason` case, exemplar lookup, and the
/// max-3 / ordering rule.
struct PlayNextReasonFormatterTests {

    private let exemplars: [Int64: ExemplarInfo] = [
        1: ExemplarInfo(title: "Bloodborne", tierLetter: "S"),
        2: ExemplarInfo(title: "Elden Ring", tierLetter: "A"),
        3: ExemplarInfo(title: "Untiered", tierLetter: nil),
    ]
    private let bracket = TimeBracket(shelf: .fewWeeks)

    private func s(_ reason: PlayNextReason) -> String {
        PlayNextReasonFormatter.sentence(for: reason, exemplars: exemplars, bracket: bracket)
    }

    @Test func sharedFranchise() {
        let out = s(.sharedFranchise(value: "Dark Souls", with: 1))
        #expect(out.contains("Dark Souls"))
        #expect(out.contains("**Bloodborne** (S)"))
    }

    @Test func sharedSeries() {
        #expect(s(.sharedSeries(value: "Souls", with: 2)).contains("**Elden Ring** (A)"))
    }

    @Test func sameDeveloper() {
        let out = s(.sameDeveloper(name: "FromSoftware", exemplar: 2))
        #expect(out == "From FromSoftware, like **Elden Ring** (A)")
    }

    @Test func similarTo() {
        #expect(s(.similarTo(1)) == "Similar to **Bloodborne** (S)")
    }

    @Test func similarToMissingExemplarDegrades() {
        #expect(s(.similarTo(999)) == "Similar to a game you ranked")
    }

    @Test func exemplarWithoutTierOmitsParen() {
        #expect(s(.similarTo(3)) == "Similar to **Untiered**")
    }

    @Test func traitAffinityPositive() {
        #expect(s(.traitAffinity(kind: .genre, value: "stealth", lift: 0.4)) == "You rate stealth games highly")
    }

    @Test func traitAffinityNegative() {
        #expect(s(.traitAffinity(kind: .genre, value: "racing", lift: -0.3)) == "Not usually your thing (racing games)")
    }

    @Test func traitAffinityPlatformAndDecade() {
        #expect(s(.traitAffinity(kind: .platform, value: "ps2", lift: 0.2)).contains("PS2 games"))
        #expect(s(.traitAffinity(kind: .decade, value: "2010", lift: 0.2)).contains("the 2010s"))
    }

    @Test func fitsBracket() {
        #expect(s(.fitsBracket(estimateSeconds: 32 * 3600, bracket: bracket)) == "≈ 32 h — fits 'A Few Weeks (10–40 h)'")
    }

    @Test func remainingTime() {
        #expect(s(.remainingTime(remainingSeconds: 12 * 3600)) == "about 12 h left")
    }

    @Test func crowdRated() {
        #expect(s(.crowdRated(rating: 91.4, count: 200)) == "Well regarded (IGDB 91)")
    }

    @Test func noMetadata() {
        #expect(s(.noMetadata) == "No metadata — matched on length only")
    }

    @Test func weakEvidence() {
        #expect(s(.weakEvidence) == "Little to go on yet")
    }

    // MARK: - Max-3 and ordering

    @Test func capsAtThreeInEngineOrder() {
        let suggestion = PlayNextSuggestion(
            id: 200, title: "Elden Ring", score: 0.9, matchStrength: .strong,
            reasons: [.sameDeveloper(name: "FromSoftware", exemplar: 1),
                      .similarTo(2),
                      .crowdRated(rating: 90, count: 100),
                      .fitsBracket(estimateSeconds: 30 * 3600, bracket: bracket)],  // 4th — dropped
            hasMetadata: true)
        let sentences = PlayNextReasonFormatter.sentences(for: suggestion, exemplars: exemplars, bracket: bracket)
        #expect(sentences.count == 3)
        #expect(sentences[0].hasPrefix("From FromSoftware"))
        #expect(sentences[2].hasPrefix("Well regarded"))
        #expect(!sentences.contains { $0.contains("fits") })   // 4th reason not shown
    }
}
