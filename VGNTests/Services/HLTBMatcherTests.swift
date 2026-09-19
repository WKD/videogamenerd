import Foundation
import Testing
@testable import VGN

/// The pure HLTB matcher (PLAN §5.3): TitleNormalizer + FuzzyMatch over name +
/// aliases, release year ± 1 as the tie-breaker, and the confident / ambiguous /
/// not-found thresholds — on the tricky pairs the spec calls out.
@Suite struct HLTBMatcherTests {

    private func candidate(_ id: Int64, _ name: String, year: Int? = nil,
                           aliases: [String] = []) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, aliases: aliases, releaseYear: year,
                      mainSeconds: 3600)
    }

    @Test func exactNameIsConfident() {
        let out = HLTBMatcher.match(title: "Bloodborne", year: 2015,
                                    candidates: [candidate(1, "Bloodborne", year: 2015)])
        guard case .confident(let c) = out else { Issue.record("expected confident"); return }
        #expect(c.id == 1)
    }

    @Test func aliasMatchIsConfident() {
        let out = HLTBMatcher.match(title: "FF7", year: 1997,
                                    candidates: [candidate(1, "Final Fantasy VII", aliases: ["FF7"])])
        guard case .confident = out else { Issue.record("expected confident via alias"); return }
    }

    @Test func numberedSequelDoesNotFalseMatchTheBase() {
        // Query "Portal 2" must not confidently match a lone "Portal".
        let out = HLTBMatcher.match(title: "Portal 2", year: 2011,
                                    candidates: [candidate(1, "Portal", year: 2007)])
        #expect(out == .notFound || {
            if case .ambiguous = out { return true }; return false
        }())
    }

    @Test func remasterIsNotConfidentlyTheOriginal() {
        // Only a "Remastered" candidate present for a base-title query → offer it,
        // never auto-fill (Remaster denotes a separate game in VGN).
        let out = HLTBMatcher.match(title: "The Last of Us", year: 2013,
                                    candidates: [candidate(1, "The Last of Us Remastered", year: 2014)])
        if case .confident = out { Issue.record("remaster should not be confident") }
    }

    @Test func sameNameDifferentYearDisambiguatesByYear() {
        // Two identically-named games; the year picks the right one confidently.
        let cands = [
            candidate(1, "Final Fantasy VII", year: 1997),
            candidate(2, "Final Fantasy VII", year: 2020),   // e.g. a re-release entry
        ]
        let out = HLTBMatcher.match(title: "Final Fantasy VII", year: 1997, candidates: cands)
        guard case .confident(let c) = out else { Issue.record("expected confident by year"); return }
        #expect(c.id == 1)
    }

    @Test func sameNameNoYearIsAmbiguous() {
        let cands = [
            candidate(1, "Tomb Raider", year: 1996),
            candidate(2, "Tomb Raider", year: 2013),
        ]
        let out = HLTBMatcher.match(title: "Tomb Raider", year: nil, candidates: cands)
        guard case .ambiguous(let list) = out else { Issue.record("expected ambiguous"); return }
        #expect(list.count == 2)
    }

    @Test func unrelatedTitleIsNotFound() {
        let out = HLTBMatcher.match(title: "Bloodborne", year: 2015,
                                    candidates: [candidate(1, "Stardew Valley", year: 2016)])
        #expect(out == .notFound)
    }

    @Test func subtitleOnlyDifferenceIsOfferedNotAutoFilled() {
        // "Persona 5" vs "Persona 5 Royal" — a distinct edition; not confident.
        let out = HLTBMatcher.match(title: "Persona 5", year: 2016,
                                    candidates: [candidate(1, "Persona 5 Royal", year: 2019)])
        if case .confident = out { Issue.record("subtitle edition should not be confident") }
    }

    @Test func emptyCandidatesAreNotFound() {
        #expect(HLTBMatcher.match(title: "Anything", year: nil, candidates: []) == .notFound)
    }
}
