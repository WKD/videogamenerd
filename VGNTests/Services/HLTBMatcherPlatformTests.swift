import Foundation
import Testing
@testable import VGN

/// The platform tie-breaker on the pure HLTB matcher (PLAN §5.3, D2): platform overlap
/// breaks a *title* tie but never overrides a better title, and two candidates that stay
/// tied after platform + year are still ambiguous.
@Suite struct HLTBMatcherPlatformTests {

    private func candidate(_ id: Int64, _ name: String, year: Int? = nil,
                           platforms: [String] = []) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, aliases: [], releaseYear: year,
                      mainSeconds: 3600, platforms: platforms)
    }

    @Test func platformBreaksATitleTieConfidently() {
        // Two identical titles, no year; only one is on my platform → auto-pick it.
        let cands = [
            candidate(1, "Tomb Raider", platforms: ["PlayStation"]),      // ps1 — mine
            candidate(2, "Tomb Raider", platforms: ["PC"]),
        ]
        let out = HLTBMatcher.match(title: "Tomb Raider", year: nil,
                                    candidates: cands, librarySlugs: ["ps1"])
        guard case .confident(let c) = out else { Issue.record("expected confident by platform"); return }
        #expect(c.id == 1)
    }

    @Test func stillAmbiguousWhenBothMatchThePlatform() {
        let cands = [
            candidate(1, "Tomb Raider", platforms: ["PlayStation"]),
            candidate(2, "Tomb Raider", platforms: ["PlayStation"]),
        ]
        let out = HLTBMatcher.match(title: "Tomb Raider", year: nil,
                                    candidates: cands, librarySlugs: ["ps1"])
        guard case .ambiguous(let list) = out else { Issue.record("expected ambiguous"); return }
        #expect(list.count == 2)
    }

    @Test func stillAmbiguousWhenNeitherMatchesThePlatform() {
        let cands = [
            candidate(1, "Tomb Raider", platforms: ["PC"]),
            candidate(2, "Tomb Raider", platforms: ["Xbox"]),
        ]
        let out = HLTBMatcher.match(title: "Tomb Raider", year: nil,
                                    candidates: cands, librarySlugs: ["switch"])
        guard case .ambiguous = out else { Issue.record("expected ambiguous"); return }
    }

    @Test func platformNeverBeatsABetterTitle() {
        // A worse title on my platform must sort BEHIND a better title that is not.
        let cands = [
            candidate(1, "Portal 2", platforms: ["PC"]),          // better title, not mine
            candidate(2, "Portal", platforms: ["PlayStation"]),   // worse title, mine
        ]
        let ranked = HLTBMatcher.scored(title: "Portal 2", year: nil,
                                        candidates: cands, librarySlugs: ["ps1"])
        #expect(ranked.first?.candidate.id == 1)
        // …and the outcome is the better title, not the platform-matching one.
        let out = HLTBMatcher.match(title: "Portal 2", year: nil,
                                    candidates: cands, librarySlugs: ["ps1"])
        guard case .confident(let c) = out else { Issue.record("expected confident best title"); return }
        #expect(c.id == 1)
    }

    @Test func platformIsInertWhenNoLibrarySlugsGiven() {
        // Same call without slugs falls back to the year/id tie-break (regression guard).
        let cands = [
            candidate(1, "Tomb Raider", platforms: ["PlayStation"]),
            candidate(2, "Tomb Raider", platforms: ["PC"]),
        ]
        let out = HLTBMatcher.match(title: "Tomb Raider", year: nil, candidates: cands)
        guard case .ambiguous = out else { Issue.record("expected ambiguous without slugs"); return }
    }
}
