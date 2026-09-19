import Foundation

/// The slim row the grid renders — deliberately *not* a full game record
/// (PLAN §9: "Grid query returns a slim row struct, not full records").
/// A DB observation in lane A produces these; UI views consume only these.
struct GameSummary: Hashable, Sendable, Identifiable {
    var id: Int64
    var title: String
    var year: Int?

    /// Filename of the cover inside the covers store (nil = no art yet).
    var coverFile: String?

    // Denormalised tier facts so the cell can draw its chip without a join.
    var tierID: Int64?
    var tierLetter: String?
    var tierColorHex: String?
    /// Fine-rank position within the tier; nil = unplaced (dimmed tail).
    var rankKey: RankKey?

    var played: Bool
    var owned: Bool
    /// True when this game is a member of a compilation product (stack marker).
    var isCompilationMember: Bool
    /// The compilation product's title, for the stack-marker tooltip (nil when not
    /// a compilation member, or the compilation has no title).
    var compilationTitle: String?
    /// The compilation product id, so "Show compilation" can select every member.
    var compilationProductID: Int64?

    /// Platform slugs this game exists on (badges / chips).
    var platformIDs: [String]

    var status: PlayStatus?

    /// True when this game is owned as a ROM on ≥ 1 platform (PLAN §4 — ROM badge).
    var hasROM: Bool

    /// True when the game is owned but **every** owned copy is a subscription copy
    /// (PLAN §13.3 — "a game I own only through PS Plus"). Drives the grid cell's yellow
    /// "+" badge and the Format ▸ "PS Plus" facet. A copy also owned on disc ⇒ false.
    var ownedOnlyViaSubscription: Bool

    init(
        id: Int64,
        title: String,
        year: Int? = nil,
        coverFile: String? = nil,
        tierID: Int64? = nil,
        tierLetter: String? = nil,
        tierColorHex: String? = nil,
        rankKey: RankKey? = nil,
        played: Bool = false,
        owned: Bool = false,
        isCompilationMember: Bool = false,
        compilationTitle: String? = nil,
        compilationProductID: Int64? = nil,
        platformIDs: [String] = [],
        status: PlayStatus? = nil,
        hasROM: Bool = false,
        ownedOnlyViaSubscription: Bool = false
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.coverFile = coverFile
        self.tierID = tierID
        self.tierLetter = tierLetter
        self.tierColorHex = tierColorHex
        self.rankKey = rankKey
        self.played = played
        self.owned = owned
        self.isCompilationMember = isCompilationMember
        self.compilationTitle = compilationTitle
        self.compilationProductID = compilationProductID
        self.platformIDs = platformIDs
        self.status = status
        self.hasROM = hasROM
        self.ownedOnlyViaSubscription = ownedOnlyViaSubscription
    }

    /// Derived Backlog membership (PLAN §4 invariant 2): owned but not played.
    var isBacklog: Bool { owned && !played }

    /// A played game that has no tier yet ("Unranked" smart list).
    var isUnranked: Bool { played && tierID == nil }
}

#if DEBUG
extension GameSummary {
    /// Preview / sample data for SwiftUI previews and the Wave 0 smoke test.
    static let samples: [GameSummary] = [
        GameSummary(
            id: 1, title: "Bloodborne", year: 2015, coverFile: nil,
            tierID: 1, tierLetter: "S", tierColorHex: "#FF3B30", rankKey: 1000,
            played: true, owned: true, platformIDs: ["ps4"], status: .completed
        ),
        GameSummary(
            id: 2, title: "Elden Ring", year: 2022,
            tierID: 1, tierLetter: "S", tierColorHex: "#FF3B30", rankKey: 2000,
            played: true, owned: true, platformIDs: ["ps5", "ps4"], status: .finished
        ),
        GameSummary(
            id: 3, title: "Metal Gear Solid 3: Snake Eater", year: 2004,
            tierID: 2, tierLetter: "A", tierColorHex: "#FF9500", rankKey: 1500,
            played: true, owned: true, isCompilationMember: true,
            platformIDs: ["ps2"], status: .finished, hasROM: true
        ),
        GameSummary(
            id: 4, title: "Broken Sword", year: 1996,
            played: true, owned: false, platformIDs: ["pc"]
        ),
        GameSummary(
            id: 5, title: "Silksong", year: 2025,
            played: false, owned: true, platformIDs: ["ps5"]
        ),
    ]
}
#endif
