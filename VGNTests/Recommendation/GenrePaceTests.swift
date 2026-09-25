import Foundation
import Testing
@testable import VGN

/// Per-genre pace (PLAN §7b "Per-genre pace"): the implausible-sample filter, the shrinkage
/// toward the global factor, the < 10 → global rule, the multi-genre mean, the override, and how
/// Play Next / the Vault plan with a game's own factor. Pure — no database.
@Suite struct GenrePaceTests {
    private let h = 3600

    private func g(_ id: Int64, _ name: String) -> PaceFactor.GenreRef { .init(id: id, name: name) }

    /// A finished game with ratio `ratio` (10 h main) in `genres`.
    private func sample(_ ratio: Double, _ genres: [PaceFactor.GenreRef] = []) -> PaceFactor.Sample {
        PaceFactor.Sample(playedSeconds: Int((ratio * 10 * 3600).rounded()), mainSeconds: 10 * h, genres: genres)
    }

    // MARK: Filter

    @Test func implausibleRatiosAreSetAsideInclusiveBounds() {
        #expect(PaceFactor.isPlausible(0.3))
        #expect(PaceFactor.isPlausible(5.0))
        #expect(!PaceFactor.isPlausible(0.29))
        #expect(!PaceFactor.isPlausible(5.01))
        // Five plausible at 1.5 plus three implausible (0.07, 0.2, 6.0): the median ignores them.
        let f = PaceFactor.compute(samples: [1.4, 1.5, 1.5, 1.6, 1.5, 0.07, 0.2, 6.0].map { sample($0) })
        #expect(f.sampleCount == 5)
        #expect(f.setAsideCount == 3)
        #expect(f.measured == 1.5)
        #expect(f.rawMedian == 1.5)
        // Unqualified samples (no estimate) are neither counted nor set aside.
        let none = PaceFactor.compute(samples: [PaceFactor.Sample(playedSeconds: 3600, mainSeconds: nil)])
        #expect(none.sampleCount == 0 && none.setAsideCount == 0)
        // Only implausible samples: unmeasured, but the set-aside count is kept.
        let allOut = PaceFactor.compute(samples: [sample(0.1), sample(9)])
        #expect(allOut.measured == 1.0 && allOut.sampleCount == 0 && allOut.setAsideCount == 2)
    }

    // MARK: Shrinkage

    /// The orchestrator's measurement on the owner's library (global 1.81), reproduced by the
    /// formula `(n·median + 5·global)/(n + 5)` (unclamped, to the table's two decimals).
    @Test(arguments: [
        ("Adventure", 98, 1.95, 1.94), ("Puzzle", 58, 2.46, 2.41), ("Point-and-click", 32, 2.94, 2.78),
        ("RPG", 25, 1.56, 1.60), ("Platform", 15, 0.07, 0.50), ("Shooter", 14, 1.32, 1.45),
        ("Indie", 13, 1.34, 1.47),
    ])
    func shrinkReproducesTheMeasuredTable(_ row: (String, Int, Double, Double)) {
        let shrunk = PaceFactor.shrink(median: row.2, sampleCount: row.1, global: 1.81)
        // The table's medians are themselves rounded to 2 decimals, hence the ±0.011.
        #expect(abs(shrunk - row.3) <= 0.011, "\(row.0): \(shrunk)")
    }

    /// Synthetic library: A 12 × 2.0 (+ 3 implausible), B 9 × 1.2 (< 10 → none), C 10 × 4.0
    /// (clamped at 2.0), 20 untagged × 1.6 → global median 1.6.
    private var synthetic: [PaceFactor.Sample] {
        let a = g(10, "Adventure"), b = g(20, "Brawler"), c = g(30, "Cozy")
        return Array(repeating: sample(2.0, [a]), count: 12)
            + [sample(0.07, [a]), sample(0.1, [a]), sample(6.0, [a])]
            + Array(repeating: sample(1.2, [b]), count: 9)
            + Array(repeating: sample(4.0, [c]), count: 10)
            + Array(repeating: sample(1.6), count: 20)
    }

    @Test func perGenreFactorsFromSyntheticSamples() {
        let f = PaceFactor.compute(samples: synthetic)
        #expect(f.sampleCount == 51)
        #expect(f.setAsideCount == 3)
        #expect(f.measured == 1.6)
        #expect(f.genres.map(\.name) == ["Adventure", "Cozy"])            // Brawler: 9 < 10
        let adventure = f.genres[0]
        #expect(adventure.sampleCount == 12)                                // implausible ones excluded
        #expect(adventure.factor == PaceProfile.quantize((12 * 2.0 + 5 * 1.6) / 17))
        #expect(f.genres[1].factor == 2.0)                                  // (40 + 8)/15 = 3.2 → clamp
        // Settings line: highest first, counts, then everything else.
        #expect(f.genreSummary == "Cozy 2.0× (10) · Adventure 1.9× (12) · everything else 1.6×")
    }

    @Test func aGenreNeedsTenPlausibleSamples() {
        let a = g(1, "Adventure")
        let nine = Array(repeating: sample(2.5, [a]), count: 9) + Array(repeating: sample(1.5), count: 5)
        #expect(PaceFactor.compute(samples: nine).genres.isEmpty)
        // Implausible samples do not count toward the ten.
        let padded = nine + [sample(0.05, [a]), sample(7, [a])]
        #expect(PaceFactor.compute(samples: padded).genres.isEmpty)
        let ten = nine + [sample(2.5, [a])]
        #expect(PaceFactor.compute(samples: ten).genres.count == 1)
        // Under the global minimum (5 plausible) there are no genre factors at all.
        #expect(PaceFactor.compute(samples: Array(repeating: sample(2.5, [a]), count: 4)).genres.isEmpty)
    }

    // MARK: Per-game factor

    @Test func aGameUsesTheMeanOfItsQualifyingGenresElseGlobal() {
        let profile = PaceFactor.compute(samples: synthetic).effective(override: nil)
        let adventure = PaceProfile.quantize((12 * 2.0 + 5 * 1.6) / 17)
        #expect(profile.factor(genreNames: ["Adventure"]) == adventure)
        #expect(profile.factor(genreNames: ["Adventure", "Cozy"]) == (adventure + 2.0) / 2)
        #expect(profile.factor(genreNames: ["Adventure", "Brawler"]) == adventure)   // Brawler not qualifying
        #expect(profile.factor(genreNames: ["Brawler"]) == 1.6)
        #expect(profile.factor(genreNames: []) == 1.6)
        #expect(profile.factor(genreNames: ["Adventure", "Adventure"]) == adventure)  // deduplicated
        #expect(profile.factor(traits: [GameTrait(kind: .genre, value: "Cozy"),
                                        GameTrait(kind: .theme, value: "Adventure")]) == 2.0)
        #expect(profile.basis(genreNames: ["Cozy", "Adventure"]) == .genres(["Adventure", "Cozy"]))
        #expect(profile.basis(genreNames: ["Brawler"]) == .global)
    }

    @Test func theOverrideReplacesEverything() {
        let measured = PaceFactor.compute(samples: synthetic)
        let profile = measured.effective(override: 1.2)
        #expect(profile.isUniform)
        #expect(profile.factor(genreNames: ["Adventure", "Cozy"]) == 1.2)
        #expect(measured.effective(override: 9).global == 2.0)
        #expect(PlayPaceModel.genrePaceSummary(measured: measured, override: 1.2) == nil)
        #expect(PlayPaceModel.genrePaceSummary(measured: measured, override: nil)?.hasPrefix("By genre: Cozy 2.0×") == true)
    }

    @Test func quantizedMeansAreExactInAnyOrder() {
        let fs = [2.779, 2.41, 1.943, 1.601, 1.449].map(PaceProfile.quantize)
        let forward = fs.reduce(0, +) / Double(fs.count)
        let backward = fs.reversed().reduce(0, +) / Double(fs.count)
        #expect(forward == backward)
    }

    @Test func genreLabels() {
        #expect(PaceFactor.genreLabel("Point-and-click") == "point-and-click")
        #expect(PaceFactor.genreLabel("Role-playing (RPG)") == "RPG")
        #expect(PaceFactor.genreLabel("Real Time Strategy (RTS)") == "RTS")
    }

    @Test func settingsSentenceNamesTheSetAside() {
        var measured = PaceFactor(measured: 1.8, sampleCount: 104, rawMedian: 1.81)
        measured.setAsideCount = 12
        #expect(PlayPaceModel.paceFactorSummary(measured: measured, override: nil)
                == "You take about 1.8× the advertised time · based on 104 finished games (12 set aside as incomplete)")
    }

    // MARK: Play Next + Vault plan per genre

    private var profile: PaceProfile {
        PaceProfile(global: 1.0, genres: [.init(id: 1, name: "Point-and-click", factor: 2.0, sampleCount: 30)])
    }

    @Test func playNextFitsEachCandidateWithItsGenreFactor() {
        // Two 25 h games in "A Few Weeks" (10–40 h): the point-and-click one is 50 h for the
        // owner (past the edge, weaker fit), the other stays 25 h.
        let ranked = (1...16).map { Rec.ranked(GameID($0), score: 0.5) }
        let pnc = Rec.candidate(100, estimateHours: 25, traits: [GameTrait(kind: .genre, value: "Point-and-click")],
                                title: "PnC")
        let other = Rec.candidate(101, estimateHours: 25, traits: [GameTrait(kind: .genre, value: "Shooter")],
                                  title: "Other")
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked, candidates: [pnc, other],
            bracket: TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst, paceFactor: profile)))
        let all = [result.hero].compactMap { $0 } + result.alternatives
        #expect(all.first { $0.id == 100 }?.estimateSeconds == 50 * h)
        #expect(all.first { $0.id == 101 }?.estimateSeconds == 25 * h)
        #expect(pnc.fullEstimate(style: .storyFirst, paceFactor: profile) == 50 * h)
        #expect(other.fullEstimate(style: .storyFirst, paceFactor: profile) == 25 * h)
    }

    @Test func vaultFitsEachEntryWithItsGenreFactor() {
        var pnc = RomCatalogEntry(id: 1, system: "ps4", platformID: "ps4", relativePath: "a", name: "A",
                                  lengthMainSeconds: 20 * h)
        pnc.traitsJSON = RomCatalogEntry.encodeTraits([GameTrait(kind: .genre, value: "Point-and-click")])
        let rom = RomCatalogEntry(id: 2, system: "ps4", platformID: "ps4", relativePath: "b", name: "B",
                                  lengthMainSeconds: 20 * h)
        let scored = DiscoverScorer.score(entries: [pnc, rom], ranked: [], options: .init(
            bracket: TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst), playStyle: .storyFirst,
            paceFactor: profile))
        func fit(_ id: Int64) -> Int? {
            scored.first { $0.entry.id == id }?.reasons.compactMap { r -> Int? in
                if case let .fitsBracket(s, _) = r { return s } else { return nil } }.first
        }
        #expect(fit(1) == 40 * h)
        #expect(fit(2) == 20 * h)
    }
}
