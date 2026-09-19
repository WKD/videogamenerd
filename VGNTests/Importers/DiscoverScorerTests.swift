import Foundation
import Testing
@testable import VGN

/// The pure Batocera "Discover" taste scorer (PLAN §15): a library that loves JRPGs surfaces
/// JRPG ROMs over higher-rated shooters, a franchise link beats a crowd rating, "Not
/// Interested" never returns, and rotation is stable within a week but changes across weeks.
struct DiscoverScorerTests {

    private func mkRanked(_ id: Int64, score: Double, traits: [GameTrait]) -> RankedGame {
        RankedGame(id: id, igdbID: nil, score: score, traits: traits)
    }

    private func entry(_ id: Int64, name: String, system: String = "snes",
                       genre: String? = nil, family: String? = nil, rating: Double? = nil) -> RomCatalogEntry {
        RomCatalogEntry(id: id, source: "batocera", system: system, platformID: system,
                        relativePath: "./\(name).zip", name: name,
                        genre: genre, family: family, rating: rating)
    }

    @Test func jrpgLibrarySurfacesJRPGOverHigherRatedShooter() {
        // A library that loves RPGs and dislikes shooters.
        var ranked: [RankedGame] = []
        for i in 0..<12 { ranked.append(mkRanked(Int64(i + 1), score: 0.9,
                                               traits: [GameTrait(kind: .genre, value: "Role-playing (RPG)")])) }
        for i in 0..<12 { ranked.append(mkRanked(Int64(i + 100), score: 0.1,
                                               traits: [GameTrait(kind: .genre, value: "Shooter")])) }

        let jrpg = entry(1, name: "Cool RPG", genre: "Role Playing Game")
        let shooter = entry(2, name: "Loud Shooter", genre: "Shoot'em Up", rating: 0.98)

        let scored = DiscoverScorer.score(entries: [jrpg, shooter], ranked: ranked)
        #expect(scored.first?.entry.id == jrpg.id)
        let jrpgScore = scored.first { $0.entry.id == jrpg.id }!.score
        let shooterScore = scored.first { $0.entry.id == shooter.id }!.score
        #expect(jrpgScore > shooterScore)
    }

    @Test func franchiseLinkBeatsCrowdRating() {
        // One neutral base library so the mean sits near 0.5, plus one S-tier Metroid.
        var ranked: [RankedGame] = (0..<10).map {
            mkRanked(Int64($0 + 1), score: 0.5, traits: [GameTrait(kind: .keyword, value: "misc")])
        }
        ranked.append(mkRanked(500, score: 0.98, traits: [GameTrait(kind: .franchise, value: "Metroid")]))

        let sameSeries = entry(1, name: "Metroid Fusion", family: "Metroid")   // no rating
        let highlyRated = entry(2, name: "Random Hit", genre: "Puzzle", rating: 0.98)

        let scored = DiscoverScorer.score(entries: [sameSeries, highlyRated], ranked: ranked)
        #expect(scored.first?.entry.id == sameSeries.id)
        // The franchise link produces a "same series" reason citing the exemplar.
        let seriesReasons = scored.first { $0.entry.id == sameSeries.id }!.reasons
        let hasFranchise = seriesReasons.contains {
            if case .sharedFranchise(let value, _) = $0 { return value == "Metroid" }
            return false
        }
        #expect(hasFranchise)
    }

    @Test func notInterestedNeverReturns() {
        let ranked = (0..<8).map { mkRanked(Int64($0 + 1), score: 0.7, traits: [GameTrait(kind: .genre, value: "Platform")]) }
        var hidden = entry(1, name: "Hidden", genre: "Platform")
        hidden.notInterested = true
        let visible = entry(2, name: "Visible", genre: "Platform")
        let scored = DiscoverScorer.score(entries: [hidden, visible], ranked: ranked)
        #expect(scored.map(\.entry.id) == [visible.id])
    }

    @Test func promotedEntriesAreExcluded() {
        let ranked = [mkRanked(1, score: 0.6, traits: [GameTrait(kind: .genre, value: "Platform")])]
        var promoted = entry(1, name: "Already Promoted", genre: "Platform")
        promoted.promotedGameID = 42
        let scored = DiscoverScorer.score(entries: [promoted], ranked: ranked)
        #expect(scored.isEmpty)
    }

    @Test func rotationSeedStableWithinWeekChangesAcrossWeeks() {
        let cal = Calendar(identifier: .iso8601)
        let week1a = DateComponents(calendar: cal, year: 2026, month: 3, day: 2).date!   // a Monday
        let week1b = DateComponents(calendar: cal, year: 2026, month: 3, day: 5).date!   // same ISO week
        let week2 = DateComponents(calendar: cal, year: 2026, month: 3, day: 10).date!   // next ISO week

        let seed1a = DiscoverModel.rotationSeed(date: week1a, shuffle: 0)
        let seed1b = DiscoverModel.rotationSeed(date: week1b, shuffle: 0)
        let seed2 = DiscoverModel.rotationSeed(date: week2, shuffle: 0)
        #expect(seed1a == seed1b)          // stable within a week
        #expect(seed1a != seed2)           // changes across weeks
        // Shuffle re-rolls within the week.
        #expect(DiscoverModel.rotationSeed(date: week1a, shuffle: 1) != seed1a)
    }

    @Test func rotationReordersNearTies() {
        // Two near-identical entries; different weekly seeds can swap their order.
        let ranked = (0..<10).map { mkRanked(Int64($0 + 1), score: 0.5, traits: [GameTrait(kind: .keyword, value: "x")]) }
        let a = entry(1, name: "Alpha", genre: "Platform", rating: 0.5)
        let b = entry(2, name: "Beta", genre: "Platform", rating: 0.5)
        var orders = Set<[Int64]>()
        for seed: UInt64 in 0..<40 {
            let scored = DiscoverScorer.score(entries: [a, b], ranked: ranked,
                                              options: .init(seed: seed))
            orders.insert(scored.map(\.entry.id))
        }
        #expect(orders.count == 2)   // both orders occur across seeds → rotation reorders ties
    }

    @Test func systemAffinityNudgesPlayedSystems() {
        let ranked = (0..<8).map { mkRanked(Int64($0 + 1), score: 0.5, traits: [GameTrait(kind: .keyword, value: "y")]) }
        let onPlayed = entry(1, name: "OnSNES", system: "snes", genre: "Platform")
        let onOther = entry(2, name: "OnNES", system: "nes", genre: "Platform")
        let scored = DiscoverScorer.score(entries: [onPlayed, onOther], ranked: ranked,
                                          options: .init(seed: 0, playedSystems: ["snes"]))
        let snes = scored.first { $0.entry.id == onPlayed.id }!.score
        let nes = scored.first { $0.entry.id == onOther.id }!.score
        #expect(snes > nes)
    }
}
