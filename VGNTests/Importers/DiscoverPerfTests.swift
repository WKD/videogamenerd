import Foundation
import Testing
@testable import VGN

/// Discover scoring over a full ~11 000-entry catalogue (PLAN §15 perf). Asserts correctness
/// (all scored, sorted, deterministic) and **prints** the timing — never a wall-clock
/// assertion (it flakes under parallel load).
struct DiscoverPerfTests {

    private let genres = ["Role Playing Game", "Platform", "Shoot'em Up", "Adventure", "Fighting",
                          "Racing, Driving", "Puzzle", "Sports", "Strategy", "Action"]
    private let families: [String?] = [nil, "Mario", "Zelda", "Sonic", "Final Fantasy", nil, nil]

    @Test(.timeLimit(.minutes(2)))
    func scoresElevenThousandEntriesQuickly() {
        var pool: [RomCatalogEntry] = []
        pool.reserveCapacity(11_300)
        for i in 0..<11_300 {
            pool.append(RomCatalogEntry(
                id: Int64(i + 1), source: "batocera", system: ["snes", "nes", "megadrive", "gba"][i % 4],
                platformID: "snes", relativePath: "./g\(i).zip", name: "Game \(i)",
                genre: genres[i % genres.count], family: families[i % families.count],
                developer: "Dev \(i % 60)", releaseYear: 1985 + (i % 20),
                rating: Double(i % 100) / 100.0))
        }
        // A realistic ranked set (~200 games with tiers/derived scores + traits).
        var ranked: [RankedGame] = []
        for i in 0..<200 {
            ranked.append(RankedGame(id: Int64(i + 1), igdbID: Int64(i + 1),
                                     score: Double((i * 37) % 100) / 100.0,
                                     traits: [GameTrait(kind: .genre, value: ["Role-playing (RPG)", "Platform", "Shooter"][i % 3]),
                                              GameTrait(kind: .developer, value: "Dev \(i % 60)")]))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let scored = DiscoverScorer.score(entries: pool, ranked: ranked, options: .init(seed: 42))
        let elapsed = start.duration(to: clock.now)
        print("DISCOVER perf: scored \(scored.count) entries against \(ranked.count) ranked games in \(elapsed)")

        #expect(scored.count == pool.count)
        // Sorted descending by score (stable id tiebreak).
        for i in 1..<min(scored.count, 500) {
            #expect(scored[i - 1].score >= scored[i].score)
        }
        // Deterministic for a fixed seed.
        let again = DiscoverScorer.score(entries: pool, ranked: ranked, options: .init(seed: 42))
        #expect(again.prefix(20).map(\.entry.id) == scored.prefix(20).map(\.entry.id))
    }
}
