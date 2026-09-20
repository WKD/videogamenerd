import Foundation
import Testing
@testable import VGN

/// A link-aware, no-network fake for the fill-service tests (D3/D4): scripts candidates
/// per query, records every query, and holds an id-key store for `rememberChosen` /
/// `linkedCandidate`.
final class LinkAwareFakeHLTB: HLTBSearching, @unchecked Sendable {
    private let byQuery: [String: [HLTBCandidate]]
    private let lock = NSLock()
    private var _queries: [String] = []
    private var _remembered: [Int64: HLTBCandidate] = [:]

    init(byQuery: [String: [HLTBCandidate]], remembered: [Int64: HLTBCandidate] = [:]) {
        self.byQuery = byQuery
        self._remembered = remembered
    }

    var queries: [String] { lock.withLock { _queries } }

    func search(title: String) async throws -> [HLTBCandidate] {
        lock.withLock { _queries.append(title) }
        return byQuery[title] ?? []
    }

    func rememberChosen(_ candidate: HLTBCandidate) async {
        lock.withLock { _remembered[candidate.id] = candidate }
    }

    func linkedCandidate(hltbID: Int64) async -> HLTBCandidate? {
        lock.withLock { _remembered[hltbID] }
    }
}

/// The fill-service ladder (D3) and refresh-by-id (D4), driven by a scripted fake.
@Suite struct HLTBRefreshByIDTests {

    private func cand(_ id: Int64, _ name: String, year: Int? = 2015,
                      platforms: [String] = []) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, releaseYear: year, mainSeconds: 3600, platforms: platforms)
    }

    // MARK: - Ladder (D3)

    @Test func ladderRetriesWithNoiseStrippedAndStopsAtFirstConfident() async throws {
        // HLTB only has the game under its clean name — rung 2 finds it.
        let fake = LinkAwareFakeHLTB(byQuery: [
            "The Witcher 3: Wild Hunt": [cand(10, "The Witcher 3: Wild Hunt")],
        ])
        let service = HLTBFillService(search: fake)
        let out = try await service.resolve(
            title: "The Witcher 3: Wild Hunt - Complete Edition", year: 2015)
        guard case .confident(let c) = out else { Issue.record("expected confident"); return }
        #expect(c.id == 10)
        #expect(fake.queries.count <= HLTBQueryLadder.maxQueries)
    }

    @Test func ladderStopsImmediatelyOnAConfidentFirstQuery() async throws {
        let fake = LinkAwareFakeHLTB(byQuery: ["Celeste": [cand(1, "Celeste")]])
        let service = HLTBFillService(search: fake)
        _ = try await service.resolve(title: "Celeste", year: 2018)
        #expect(fake.queries == ["Celeste"])   // one query, no wasted requests
    }

    @Test func platformBreaksAnAmbiguousLadderResult() async throws {
        let fake = LinkAwareFakeHLTB(byQuery: [
            "Tomb Raider": [cand(1, "Tomb Raider", year: nil, platforms: ["PlayStation"]),
                            cand(2, "Tomb Raider", year: nil, platforms: ["PC"])],
        ])
        let service = HLTBFillService(search: fake)
        let out = try await service.resolve(title: "Tomb Raider", year: nil, librarySlugs: ["ps1"])
        guard case .confident(let c) = out else { Issue.record("expected confident by platform"); return }
        #expect(c.id == 1)
    }

    // MARK: - Refresh by id (D4)

    @Test func refreshByIDIsExactAndNeverAmbiguous() async throws {
        // Two same-named candidates; the stored id disambiguates with no ask.
        let fake = LinkAwareFakeHLTB(byQuery: [
            "Beta": [cand(20, "Beta", year: 1996), cand(21, "Beta", year: 2013)],
        ])
        let service = HLTBFillService(search: fake)
        let out = try await service.resolveLinked(title: "Beta", year: nil, hltbID: 21)
        guard case .exact(let c) = out else { Issue.record("expected exact"); return }
        #expect(c.id == 21)
    }

    @Test func refreshByIDUsesTheRememberedCanonicalNameAsTheOnlyQuery() async throws {
        let fake = LinkAwareFakeHLTB(
            byQuery: ["Final Fantasy VII": [cand(99, "Final Fantasy VII")]],
            remembered: [99: cand(99, "Final Fantasy VII")])
        let service = HLTBFillService(search: fake)
        let out = try await service.resolveLinked(
            title: "Final Fantasy VII - Some Weird Stored Title", year: 1997, hltbID: 99)
        guard case .exact = out else { Issue.record("expected exact via remembered name"); return }
        #expect(fake.queries == ["Final Fantasy VII"])   // remembered name, not the ladder
    }

    @Test func refreshByIDFallsBackWhenTheIDIsGone() async throws {
        // HLTB no longer returns the stored id → .lost with a normal-matching outcome.
        let fake = LinkAwareFakeHLTB(byQuery: [
            "Beta": [cand(30, "Beta", year: 2013)],
        ])
        let service = HLTBFillService(search: fake)
        let out = try await service.resolveLinked(title: "Beta", year: 2013, hltbID: 21)
        guard case .lost(let outcome) = out else { Issue.record("expected lost"); return }
        // The fallback offered the still-present same-named candidate (confident here).
        if case .notFound = outcome { Issue.record("expected a re-pick candidate, not notFound") }
    }
}
