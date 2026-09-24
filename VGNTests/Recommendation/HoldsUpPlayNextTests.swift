import Foundation
import Testing
import GRDB
@testable import VGN

/// Play Next for "Holds up today?" (PLAN §7b): the mark adjusts the CANDIDATE only — Holds Up
/// +bonus, Of Its Time −penalty, Too Archaic excluded (counted) unless "Include too archaic",
/// unrated 0 — with a reason sentence; the taste profile / backtest never see it; the
/// backtest's optional first-played cutoff reports the drift.
@Suite struct HoldsUpPlayNextTests {

    private func profile() -> [RankedGame] {
        (1...16).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
    }

    private func candidate(_ mark: HoldsUp?, id: GameID = 100) -> Candidate {
        Rec.candidate(id, status: .playedUnknown, estimateHours: 20, traits: [Rec.trait(.genre, "RPG")],
                      title: "G", holdsUp: mark)
    }

    private func run(_ candidates: [Candidate], includeArchaic: Bool = false) -> PlayNextResult {
        RecommendationEngine.recommend(RecommendationInput(
            ranked: profile(), candidates: candidates, bracket: Rec.month(),
            options: RecommendationOptions(includePlayedWithoutStatus: true, includeArchaic: includeArchaic, seed: 0)))
    }

    private func heroScore(_ mark: HoldsUp?, includeArchaic: Bool = false) -> Double? {
        run([candidate(mark)], includeArchaic: includeArchaic).hero?.score
    }

    @Test func bonusAndPenaltyAreTheConfiguredSizes() throws {
        let w = RecommendationWeights()
        #expect(w.holdsUpBonus == 0.04)
        #expect(w.ofItsTimePenalty == 0.04)
        let base = try #require(heroScore(nil))
        let up = try #require(heroScore(.holdsUp))
        let dated = try #require(heroScore(.ofItsTime))
        #expect(abs((up - base) - w.holdsUpBonus) < 1e-9)
        #expect(abs((base - dated) - w.ofItsTimePenalty) < 1e-9)
        #expect(RecommendationEngine.holdsUpAdjustment(nil, weights: w) == 0)
    }

    @Test func holdsUpBreaksATieInItsFavour() throws {
        // Two identical candidates; the one that holds up wins, the dated one sinks.
        let result = run([candidate(.ofItsTime, id: 100), candidate(nil, id: 101), candidate(.holdsUp, id: 102)])
        #expect(result.shortlist.map(\.id) == [102, 101, 100])
    }

    @Test func tooArchaicIsExcludedAndCountedUnlessIncluded() throws {
        let excluded = run([candidate(.tooArchaic, id: 100), candidate(nil, id: 101)])
        #expect(excluded.shortlist.map(\.id) == [101])
        #expect(excluded.exclusions.tooArchaic == 1)
        #expect(excluded.exclusions.total == 1)

        let included = run([candidate(.tooArchaic, id: 100), candidate(nil, id: 101)], includeArchaic: true)
        #expect(Set(included.shortlist.map(\.id)) == [100, 101])
        #expect(included.exclusions.tooArchaic == 0)
        let archaic = try #require(included.shortlist.first { $0.id == 100 })
        #expect(archaic.reasons.contains(.markedTooArchaic))
        // Included, it carries the "of its time" penalty — it never outranks an equal unrated game.
        #expect(included.shortlist.first?.id == 101)
    }

    @Test func reasonsAndSentences() throws {
        let up = try #require(run([candidate(.holdsUp)]).hero)
        #expect(up.reasons.contains(.markedHoldsUp))
        #expect(up.holdsUp == .holdsUp)
        let dated = try #require(run([candidate(.ofItsTime)]).hero)
        #expect(dated.reasons.contains(.markedOfItsTime))
        let plain = try #require(run([candidate(nil)]).hero)
        #expect(!plain.reasons.contains { [.markedHoldsUp, .markedOfItsTime, .markedTooArchaic].contains($0) })

        let s1 = PlayNextReasonFormatter.sentences(for: up, exemplars: [:], bracket: Rec.month())
        #expect(s1.contains("You marked it as holding up today"))
        let s2 = PlayNextReasonFormatter.sentences(for: dated, exemplars: [:], bracket: Rec.month())
        #expect(s2.contains("You marked it as of its time"))
    }

    /// The taste profile is untouched: a candidate's traits score the same with or without
    /// a mark on the RANKED side — and the mark is not even an input of `RankedGame`, so a
    /// nostalgic S keeps training "I love what this game does".
    @Test func profileAndLinksIgnoreTheMark() throws {
        // Score deltas are exactly the configured terms, i.e. taste/crowd/time are unchanged.
        let w = RecommendationWeights()
        let base = try #require(heroScore(nil))
        #expect(abs(try #require(heroScore(.holdsUp)) - (base + w.holdsUpBonus)) < 1e-9)
    }

    // MARK: - Backtest neutrality (store level) + cutoff

    /// Identical ρ with and without marks on the owner's library (the store never feeds the
    /// mark to `predict`).
    @Test func backtestIsIdenticalWithAndWithoutMarks() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let rank = RankingStore(db)
        var ids: [Int64] = []
        for i in 0..<20 {
            let tier: Int64 = i < 10 ? 1 : 5
            let id = try await lib.addGame(GameDraft(
                title: "Game \(i)", igdbID: Int64(1000 + i), platformIDs: ["ps4"],
                owned: true, played: true, tierID: tier)).gameID
            try await lib.updateMetadata(gameID: id, MetadataPatch(
                traits: [GameTrait(kind: .keyword, value: i < 10 ? "loved" : "meh")]))
            try await rank.move(gameID: id, toTier: tier, atIndex: 0)
            ids.append(id)
        }
        let rec = RecommendationStore(db)
        let before = try await rec.backtest()
        try await lib.setHoldsUp(.tooArchaic, for: Array(ids.prefix(7)))
        try await lib.setHoldsUp(.holdsUp, for: Array(ids.suffix(6)))
        let after = try await rec.backtest()
        #expect(before.spearman != nil)
        #expect(before.spearman == after.spearman)
        #expect(before.sampleCount == after.sampleCount)
    }

    @Test func cutoffDropsOnlyGamesWithAKnownEarlierFirstPlayedYear() throws {
        // 20 "loved" games first played in the 80s (nostalgia), 20 "meh" games with no date.
        var ranked: [RankedGame] = []
        for i in 0..<20 {
            var g = Rec.ranked(GameID(i + 1), score: 0.70 + Double(i) * 0.012, [Rec.trait(.keyword, "loved")])
            g.firstPlayedYear = 1986 + (i % 5)
            ranked.append(g)
        }
        for i in 0..<20 {
            ranked.append(Rec.ranked(GameID(i + 100), score: 0.05 + Double(i) * 0.010, [Rec.trait(.keyword, "meh")]))
        }
        let result = TasteBacktest.run(ranked: ranked, excludingFirstPlayedBefore: 1995)
        let full = TasteBacktest.run(ranked: ranked)
        #expect(result.spearman == full.spearman)                 // headline unchanged
        let cutoff = try #require(result.cutoff)
        #expect(cutoff.year == 1995)
        #expect(cutoff.excludedCount == 20)                        // only the dated early ones
        #expect(cutoff.sampleCount == 20)                          // undated games stay in
        #expect(TasteBacktest.run(ranked: ranked, excludingFirstPlayedBefore: nil).cutoff == nil)

        // A cutoff before every date removes nothing and reproduces ρ exactly.
        let none = try #require(TasteBacktest.run(ranked: ranked, excludingFirstPlayedBefore: 1980).cutoff)
        #expect(none.excludedCount == 0)
        #expect(none.spearman == full.spearman)
    }

    @Test func driftLineReadsLikeTheSpec() {
        var r = TasteBacktestResult(spearman: 0.52, sampleCount: 60, verdict: .good)
        #expect(r.driftLine == "ρ = 0.52")
        r.cutoff = .init(year: 1995, spearman: 0.41, sampleCount: 44, excludedCount: 16)
        #expect(r.driftLine == "ρ = 0.52 · without pre-1995 games: 0.41")
        r.cutoff?.spearman = nil
        #expect(r.driftLine == "ρ = 0.52 · without pre-1995 games: —")
    }

    /// The store loads the importer-filled first-played year into the ranked games.
    @Test func storeLoadsFirstPlayedYearAndCandidateMark() async throws {
        let db = try await TestDB.makeSeeded()
        let lib = LibraryStore(db)
        let id = try await lib.addGame(GameDraft(title: "Old", igdbID: 1, platformIDs: ["ps4"],
                                                 owned: true, played: true, tierID: 1)).gameID
        let first = ISO8601DateFormatter().date(from: "1991-07-01T12:00:00Z")!
        try await db.dbWriter.write { db in
            try LibraryStore.setPSNPlayedDates(gameID: id, first: first, last: first, db: db)
        }
        try await lib.setHoldsUp(.ofItsTime, for: [id])
        let ranked = try await RecommendationStore(db).rankedGames()
        #expect(ranked.first { $0.id == id }?.firstPlayedYear == 1991)
        let candidate = try await db.dbWriter.read { db in
            try RecommendationStore.loadCandidates(db: db).first { $0.id == id }
        }
        #expect(candidate?.holdsUp == .ofItsTime)
        #expect(candidate?.firstPlayedAt == first)
    }
}
