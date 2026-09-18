import Foundation

extension TierInfo {
    /// The default S A B C D F tiers (PLAN §1). Labels/colours become editable
    /// later; this is what previews and the pre-live UI render against. Lives in
    /// the UI layer because `VGN/Model` is read-only this wave.
    static let defaultTiers: [TierInfo] = [
        TierInfo(id: 1, letter: "S", label: "Masterpiece", colorHex: "#FF3B30", sort: 0),
        TierInfo(id: 2, letter: "A", label: "Excellent",   colorHex: "#FF9500", sort: 1),
        TierInfo(id: 3, letter: "B", label: "Good",        colorHex: "#FFCC00", sort: 2),
        TierInfo(id: 4, letter: "C", label: "Average",     colorHex: "#34C759", sort: 3),
        TierInfo(id: 5, letter: "D", label: "Bad",         colorHex: "#30B0C7", sort: 4),
        TierInfo(id: 6, letter: "F", label: "Awful",       colorHex: "#8E8E93", sort: 5),
    ]
}

/// A `LibraryDataSource` backed by in-memory sample values. Emits each stream
/// once and finishes (nothing mutates it). This is what the app uses in DEBUG
/// until the GRDB-backed source lands, and what every `#Preview` injects.
struct PreviewLibraryDataSource: LibraryDataSource {
    var sampleGames: [GameSummary]
    var samplePlatforms: [PlatformInfo]
    var sampleTiers: [TierInfo]

    init(
        games: [GameSummary],
        platforms: [PlatformInfo]? = nil,
        tiers: [TierInfo] = TierInfo.defaultTiers
    ) {
        self.sampleGames = games
        if let platforms {
            self.samplePlatforms = platforms
        } else {
            // Platforms "in use" = those the sample games actually reference.
            let inUse = Set(games.flatMap(\.platformIDs))
            self.samplePlatforms = PlatformLabels.all.filter { inUse.contains($0.id) }
        }
        self.sampleTiers = tiers
    }

    func sidebarCounts() -> AsyncStream<SidebarCounts> {
        onceStream(SidebarCounts.derive(from: sampleGames))
    }

    func platformsInUse() -> AsyncStream<[PlatformInfo]> {
        onceStream(samplePlatforms)
    }

    func tiers() -> AsyncStream<[TierInfo]> {
        onceStream(sampleTiers)
    }

    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> {
        onceStream(LibraryFilterEvaluator.apply(filter, to: sampleGames))
    }

    func gameDetail(id: Int64) async -> GameSummary? {
        sampleGames.first { $0.id == id }
    }
}

extension PreviewLibraryDataSource {
    /// An empty library (drives the empty-state UI).
    static var empty: PreviewLibraryDataSource { .init(games: []) }

    #if DEBUG
    /// The sample library from `GameSummary.samples`.
    static var sampled: PreviewLibraryDataSource { .init(games: GameSummary.samples) }

    /// A larger synthetic library for eyeballing grid performance / density.
    static var large: PreviewLibraryDataSource {
        var games: [GameSummary] = []
        let platforms = ["ps5", "ps4", "ps2", "switch", "snes", "pc", "xbox360", "gamecube"]
        let tiers = TierInfo.defaultTiers
        for i in 0..<240 {
            let played = i % 4 != 0
            let hasTier = played && i % 3 != 0
            let tier = tiers[i % tiers.count]
            games.append(
                GameSummary(
                    id: Int64(100 + i),
                    title: "Sample Game \(i + 1)\(i % 7 == 0 ? " with a Rather Long Subtitle Edition" : "")",
                    year: 1990 + (i % 35),
                    tierID: hasTier ? tier.id : nil,
                    tierLetter: hasTier ? tier.letter : nil,
                    tierColorHex: hasTier ? tier.colorHex : nil,
                    rankKey: hasTier ? RankKey(i * 100) : nil,
                    played: played,
                    owned: i % 5 != 0,
                    isCompilationMember: i % 11 == 0,
                    platformIDs: [platforms[i % platforms.count]],
                    status: played ? PlayStatus.allCases[i % PlayStatus.allCases.count] : nil
                )
            )
        }
        return .init(games: games)
    }
    #endif
}
