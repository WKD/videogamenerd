import Foundation
import Testing
@testable import VGN

/// Wave 21 lane B — the HLTB write rule (D1a), the order-free token-set scorer and the matcher
/// on top of it (D2a), the subtitle-swapped ladder (D2b) and the pooled "never not-found while
/// something plausible came back" verdict (D2c). Pure / fake-backed, no network.
@Suite struct HLTBMatchingW21Tests {

    private let h = 3600

    // MARK: - D1a: the write rule

    @Test func mappedTimesTable() {
        // Akira (NES): Main Story only → main AND rushed, completionist empty (never fabricated).
        let akira = HLTBCandidate(id: 29582, name: "Akira", releaseYear: 1988, mainSeconds: 8070,
                                  allStylesSeconds: 8070, mainCount: 2)
        #expect(akira.mappedTimes == HLTBMappedTimes(hastily: 8070, normally: 8070, completely: nil,
                                                     mainStoryUsedForMain: true))
        #expect(akira.usedMainStoryForMain)
        #expect(akira.hasAnyTime)

        // All three → the classic mapping.
        let full = HLTBCandidate(id: 1, name: "F", mainSeconds: 10 * h, mainExtraSeconds: 15 * h,
                                 completionistSeconds: 30 * h)
        #expect(full.mappedTimes == HLTBMappedTimes(hastily: 10 * h, normally: 15 * h, completely: 30 * h))
        #expect(!full.usedMainStoryForMain)

        // Main+Extra only → main; no rushed invented.
        let plusOnly = HLTBCandidate(id: 2, name: "P", mainExtraSeconds: 12 * h)
        #expect(plusOnly.mappedTimes == HLTBMappedTimes(hastily: nil, normally: 12 * h, completely: nil))

        // Only the All Styles average → main slot only, flagged as such.
        let allOnly = HLTBCandidate(id: 3, name: "A", allStylesSeconds: 9 * h)
        #expect(allOnly.mappedTimes == HLTBMappedTimes(hastily: nil, normally: 9 * h, completely: nil,
                                                       allStylesUsedForMain: true))
        // … but never when Main Story exists.
        let mainAndAll = HLTBCandidate(id: 4, name: "M", mainSeconds: 5 * h, allStylesSeconds: 9 * h)
        #expect(mainAndAll.mappedTimes.normally == 5 * h)

        // Zeros are "no data"; completionist-only stays completionist-only.
        let zeros = HLTBCandidate(id: 5, name: "Z", mainSeconds: 0, mainExtraSeconds: 0,
                                  completionistSeconds: 0, allStylesSeconds: 0)
        #expect(!zeros.hasAnyTime)
        let fullOnly = HLTBCandidate(id: 6, name: "C", completionistSeconds: 40 * h)
        #expect(fullOnly.mappedTimes == HLTBMappedTimes(hastily: nil, normally: nil, completely: 40 * h))
    }

    @Test func endpointParsesAllStylesAndCountsAdditively() throws {
        let list = try HLTBEndpoint.parseCandidates(try Fixtures.data("hltb-link-akira.json"))
        let akira = try #require(list.first)
        #expect(akira.id == 29582 && akira.mainSeconds == 8070)
        #expect(akira.mainExtraSeconds == nil && akira.completionistSeconds == nil)   // 0 → nil
        #expect(akira.allStylesSeconds == 8070)
        #expect(akira.mainCount == 2 && akira.mainExtraCount == nil)
        #expect(akira.timesLine.contains("Main Story only (2 reports)"))

        // An id-keyed cache entry written before wave 21 (no new keys) still decodes.
        let old = #"{"id":7,"name":"Old","aliases":[],"releaseYear":2001,"mainSeconds":3600,"platforms":[]}"#
        let decoded = try JSONDecoder().decode(HLTBCandidate.self, from: Data(old.utf8))
        #expect(decoded.allStylesSeconds == nil && decoded.mainCount == nil)
        #expect(decoded.mappedTimes.normally == 3600)
    }

    // MARK: - D2a: token-set scorer

    private static let gk2 = "Gabriel Knight II: The Beast Within"
    private static let beastWithin = "The Beast Within: A Gabriel Knight Mystery"

    @Test func tokenSetScoreTable() {
        // The owner's pair: same words, another order + a series tag → confident on text.
        let gk = TitleTokenSet.score(Self.beastWithin, Self.gk2)
        #expect(gk >= HLTBMatcher.confidentThreshold, "GK pair \(gk)")
        #expect(abs(gk - 0.94) < 0.0001)                             // 0.90 + 0.05 × 4/5
        // Same words, any order, roman ↔ arabic, stopwords → the same-set score.
        #expect(TitleTokenSet.score("Gabriel Knight 2 Beast Within", Self.gk2) == TitleTokenSet.sameSetScore)

        // Counter-cases: never confident on the token set.
        let counter: [(String, String)] = [
            ("Resident Evil 2", "Resident Evil"),
            ("Doom 3", "Doom"),
            ("Gabriel Knight: Sins of the Fathers", Self.gk2),
            ("Tomb Raider", "Rise of the Tomb Raider"),
            ("Final Fantasy VII", "Final Fantasy VII Remake"),
            ("Star Wars Battlefront", "Star Wars Battlefront: Renegade Squadron"),
            ("Metal Gear Solid", "Metal Gear Solid 2: Sons of Liberty"),
            ("The Last of Us", "The Last of Us Remastered"),
            (Self.beastWithin, "Slain 2: The Beast Within"),
        ]
        for (a, b) in counter {
            let s = TitleTokenSet.score(a, b)
            #expect(s < HLTBMatcher.confidentThreshold, "\(a) vs \(b) scored \(s)")
        }
        // Nothing to compare → 0.
        #expect(TitleTokenSet.score("(USA)", "Doom") == 0)
    }

    @Test func seriesTagDetection() {
        #expect(TitleTokenSet.seriesTag(in: Self.beastWithin)
                == TitleTokenSet.SeriesTag(main: "The Beast Within", series: "Gabriel Knight"))
        #expect(TitleTokenSet.seriesTag(in: "Batman: Arkham Knight – Season of Infamy") == nil)
        #expect(TitleTokenSet.seriesTag(in: "NieR: Automata") == nil)
        #expect(TitleTokenSet.seriesTag(in: "The Legend of Zelda: The Wind Waker") == nil)
        #expect(TitleTokenSet.seriesTag(in: "Sherlock Holmes: A Game of Shadows") == nil)   // "Shadows" isn't a genre
    }

    // MARK: - D2a: the matcher (base = max(fuzzy, token set); thresholds unchanged)

    private func cand(_ id: Int64, _ name: String, _ year: Int?) -> HLTBCandidate {
        HLTBCandidate(id: id, name: name, releaseYear: year, mainSeconds: 10 * h)
    }

    @Test func matcherBeastWithinIsConfidentWithTheYear() {
        let list = [cand(3811, Self.gk2, 1995), cand(150001, "Slain 2: The Beast Within", 2027)]
        // The owner's "not found": the old matcher scored rung 3's candidates against the rung-3
        // QUERY ("The Beast Within") only, where fuzzy is under plausible; against the full
        // title fuzzy is plausible but never confident. The token set makes it confident.
        #expect(FuzzyMatch.bestScore(query: "The Beast Within", names: [Self.gk2]) < HLTBMatcher.plausibleThreshold)
        #expect(FuzzyMatch.bestScore(query: Self.beastWithin, names: [Self.gk2]) < HLTBMatcher.confidentThreshold)
        let scored = HLTBMatcher.scored(title: Self.beastWithin, year: 1995, candidates: list)
        #expect(scored.first?.candidate.id == 3811)
        #expect((scored.first?.base ?? 0) >= HLTBMatcher.plausibleThreshold)
        #expect(abs((scored.first?.adjusted ?? 0) - (scored.first!.base + 0.06)) < 0.0001)   // 1995 vs 1995
        guard case .confident(let c) = HLTBMatcher.match(title: Self.beastWithin, year: 1995, candidates: list)
        else { Issue.record("expected confident"); return }
        #expect(c.id == 3811)
        // Scored against the rung-3 query too — still the same winner.
        guard case .confident(let viaQuery) = HLTBMatcher.match(
            title: Self.beastWithin, year: 1995, candidates: list, query: "The Beast Within")
        else { Issue.record("expected confident via query"); return }
        #expect(viaQuery.id == 3811)
    }

    @Test func matcherCounterCasesAreNeverConfident() {
        let cases: [(String, Int, HLTBCandidate)] = [
            ("Resident Evil 2", 1998, cand(1, "Resident Evil", 1996)),
            ("Resident Evil", 1996, cand(2, "Resident Evil 2", 1998)),
            ("Doom 3", 2004, cand(3, "Doom", 1993)),
            ("Doom", 1993, cand(4, "Doom 3", 2004)),
            ("Gabriel Knight: Sins of the Fathers", 1993, cand(5, Self.gk2, 1995)),
        ]
        for (title, year, c) in cases {
            if case .confident = HLTBMatcher.match(title: title, year: year, candidates: [c]) {
                Issue.record("\(title) must not be confident on \(c.name)")
            }
        }
    }

    // MARK: - D2b: the ladder

    @Test func ladderSwapsASeriesTagSubtitle() {
        #expect(HLTBQueryLadder.queries(for: Self.beastWithin)
                == [Self.beastWithin, "Gabriel Knight Beast Within", "The Beast Within"])
        #expect(HLTBQueryLadder.subtitleSwapped(Self.beastWithin) == "Gabriel Knight Beast Within")

        // Ordinary subtitles keep the old ladder, full title first.
        let batman = "Batman: Arkham Knight – Season of Infamy"
        #expect(HLTBQueryLadder.subtitleSwapped(batman) == nil)
        #expect(HLTBQueryLadder.queries(for: batman).first == batman)
        #expect(HLTBQueryLadder.queries(for: batman).count <= HLTBQueryLadder.maxQueries)
        #expect(HLTBQueryLadder.queries(for: "NieR: Automata") == ["NieR: Automata", "NieR"])
        let zelda = "The Legend of Zelda: The Wind Waker"
        #expect(HLTBQueryLadder.subtitleSwapped(zelda) == nil)
        #expect(HLTBQueryLadder.queries(for: zelda).first == zelda)
    }

    @Test func zeldaStillMatchesOnTheFullTitleWithOneQuery() async throws {
        let zelda = "The Legend of Zelda: The Wind Waker"
        let fake = LinkAwareFakeHLTB(byQuery: [zelda: [cand(9, zelda, 2002)]])
        let out = try await HLTBFillService(search: fake).resolve(title: zelda, year: 2002)
        guard case .confident(let c) = out else { Issue.record("expected confident"); return }
        #expect(c.id == 9)
        #expect(fake.queries == [zelda])
    }

    @Test func beastWithinResolvesThroughTheLadder() async throws {
        // Rung 1 (full) → nothing; rung 2 (swapped) → nothing; rung 3 → GK2 + Slain.
        let fake = LinkAwareFakeHLTB(byQuery: [
            "The Beast Within": [cand(3811, Self.gk2, 1995), cand(150001, "Slain 2: The Beast Within", 2027)],
        ])
        let out = try await HLTBFillService(search: fake).resolve(title: Self.beastWithin, year: 1995)
        guard case .confident(let c) = out else { Issue.record("expected confident, got \(out)"); return }
        #expect(c.id == 3811)
        #expect(fake.queries == [Self.beastWithin, "Gabriel Knight Beast Within", "The Beast Within"])
    }

    // MARK: - D2c: never not-found while something plausible came back

    @Test func plausibleRowsFromDifferentRungsArePooledIntoAPick() async throws {
        // Two rungs, each with one plausible-but-not-confident candidate: the verdict offers both
        // (the old code kept only the last rung's list).
        let title = "Resident Evil 2: Deluxe Edition"
        let queries = HLTBQueryLadder.queries(for: title)
        #expect(queries.count >= 2)
        let fake = LinkAwareFakeHLTB(byQuery: [
            queries[0]: [cand(1, "Resident Evil 2 Remake", 2019)],
            queries[1]: [cand(2, "Resident Evil", 1996)],
        ])
        let out = try await HLTBFillService(search: fake).resolve(title: title, year: 1998)
        guard case .ambiguous(let list) = out else { Issue.record("expected ambiguous, got \(out)"); return }
        #expect(Set(list.map(\.id)) == [1, 2])
    }

    @Test func notFoundOnlyWhenNothingPlausibleCameBack() async throws {
        let fake = LinkAwareFakeHLTB(byQuery: ["Zzyzx Quest": [cand(1, "Totally Different Game", 2000)]])
        let out = try await HLTBFillService(search: fake).resolve(title: "Zzyzx Quest", year: 2000)
        #expect(out == .notFound)
    }

    // MARK: - D3: cache pass first

    @Test func aCachedLaterRungAnswersBeforeAnyRequest() async throws {
        // Rung 1 + rung 3 cached (the owner's cache), rung 2 not: the cache pass finds the
        // confident GK2 on rung 3 and never asks rung 2.
        let fake = CacheAwareFakeHLTB(cached: [
            Self.beastWithin: [],
            "The Beast Within": [cand(3811, Self.gk2, 1995), cand(150001, "Slain 2: The Beast Within", 2027)],
        ])
        let out = try await HLTBFillService(search: fake).resolve(title: Self.beastWithin, year: 1995)
        guard case .confident(let c) = out else { Issue.record("expected confident"); return }
        #expect(c.id == 3811)
        #expect(fake.networkQueries.isEmpty)
    }

    @Test func bypassSkipsTheCachePass() async throws {
        let fake = CacheAwareFakeHLTB(cached: ["Celeste": [cand(1, "Celeste", 2018)]])
        _ = try await HLTBFillService(search: fake).resolve(title: "Celeste", year: 2018, policy: .bypassOne)
        #expect(fake.networkQueries == ["Celeste"])
    }
}

/// A fake with a scripted "cache" (served by `cachedCandidates`, zero requests) and a
/// recorded "network" (`search`), for the wave-21 cache-pass tests.
final class CacheAwareFakeHLTB: HLTBSearching, @unchecked Sendable {
    private let cached: [String: [HLTBCandidate]]
    private let network: [String: [HLTBCandidate]]
    private let lock = NSLock()
    private var _networkQueries: [String] = []

    init(cached: [String: [HLTBCandidate]], network: [String: [HLTBCandidate]] = [:]) {
        self.cached = cached
        self.network = network
    }

    var networkQueries: [String] { lock.withLock { _networkQueries } }

    func search(title: String) async throws -> [HLTBCandidate] {
        try await search(title: title, policy: .cacheFirst)
    }

    func search(title: String, policy: HLTBFreshnessPolicy) async throws -> [HLTBCandidate] {
        if policy == .cacheFirst, let hit = cached[title] { return hit }
        lock.withLock { _networkQueries.append(title) }
        return network[title] ?? cached[title] ?? []
    }

    func cachedCandidates(title: String) async -> [HLTBCandidate]? { cached[title] }
}
