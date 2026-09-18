import Foundation

#if DEBUG
/// Synthetic library generator for the `-VGNSeedGames <n>` performance mode
/// (PLAN §9/§10). DEBUG-only, in-memory, no network: fills a throwaway database
/// with `n` realistic-looking games spread across platforms, decades, tiers and
/// ownership formats so the grid / search / filters can be exercised at scale.
enum PerfSeeder {
    private static let adjectives = [
        "Shadow", "Crimson", "Eternal", "Silent", "Broken", "Golden", "Frozen",
        "Hidden", "Savage", "Radiant", "Ancient", "Neon", "Iron", "Velvet",
        "Twilight", "Phantom", "Wild", "Sacred", "Lost", "Rising",
    ]
    private static let nouns = [
        "Kingdom", "Legacy", "Odyssey", "Requiem", "Chronicles", "Frontier",
        "Ascension", "Covenant", "Horizon", "Empire", "Sonata", "Vanguard",
        "Reckoning", "Descent", "Saga", "Paradox", "Uprising", "Exile",
        "Dominion", "Genesis",
    ]
    /// Common platform slugs from the seeded catalogue.
    private static let platforms = [
        "ps5", "ps4", "ps3", "ps2", "ps1", "snes", "nes", "genesis", "pc",
        "switch", "gba", "n64",
    ]

    /// Generate `count` drafts. Every game is owned or played (so none is an
    /// orphan), tiers are spread over the six letters, and formats cycle
    /// physical / digital / ROM.
    static func makeDrafts(count: Int, tierIDs: [Int64]) -> [GameDraft] {
        (0..<count).map { i in
            let adj = adjectives[i % adjectives.count]
            let noun = nouns[(i / adjectives.count) % nouns.count]
            let title = "\(adj) \(noun) \(i + 1)"
            let platform = platforms[i % platforms.count]
            let year = 1985 + (i % 40)
            let owned = i % 5 != 0                        // ~80% owned
            // Tier ~1 game in 3 of those that are played, cycling the six tiers.
            let tierID: Int64? = (i % 3 == 0 && !tierIDs.isEmpty) ? tierIDs[(i / 3) % tierIDs.count] : nil
            // Every game is owned or played (never an orphan); a tier implies played.
            let played = (i % 3 != 0) || !owned || tierID != nil
            let format: ProductFormat = [.physical, .digital, .rom][i % 3]
            return GameDraft(
                title: title,
                igdbID: Int64(9_000_000 + i),
                year: year,
                platformIDs: [platform],
                owned: owned,
                played: played,
                tierID: tierID,
                format: format
            )
        }
    }

    /// Seed `count` games into `store` (chunked so no single transaction is huge).
    static func seed(into store: LibraryStore, count: Int) async {
        guard count > 0 else { return }
        let tierIDs = (try? await store.tiers().map(\.id)) ?? []
        let drafts = makeDrafts(count: count, tierIDs: tierIDs)
        let chunkSize = 500
        for start in stride(from: 0, to: drafts.count, by: chunkSize) {
            let slice = Array(drafts[start..<min(start + chunkSize, drafts.count)])
            _ = try? await store.addGames(slice)
        }
    }
}
#endif
