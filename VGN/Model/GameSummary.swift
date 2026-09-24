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

    /// "Holds up today?" (PLAN §7b, v16) — `nil` = Unrated. Only a played game carries one.
    var holdsUp: HoldsUp?

    /// True when this game is owned as a ROM on ≥ 1 platform (PLAN §4 — ROM badge).
    var hasROM: Bool

    /// True when the game is owned but **every** owned copy is a subscription copy
    /// (PLAN §13.3 — "a game I own only through PS Plus"). Drives the Format ▸ "PS Plus"
    /// facet and the a11y state. A copy also owned on disc ⇒ false.
    var ownedOnlyViaSubscription: Bool

    // MARK: Per-format ownership facts (PLAN §8 grid badges — one badge per distinct
    // format among the *really-owned* copies; a subscription/PS Plus claim is drawn
    // separately). The platform-id lists (deduped, source order) drive each badge's
    // tooltip "Physical · PS3" / "Digital · PS5, PC" (owner request, wave 17).

    /// Platforms of the game's really-owned **physical** copies (`subscription IS NULL`).
    var physicalPlatformIDs: [String]
    /// Platforms of the game's really-owned **digital** copies (`subscription IS NULL`).
    var digitalPlatformIDs: [String]
    /// Platforms of the game's **ROM** copies.
    var romPlatformIDs: [String]
    /// Platforms of the game's **subscription** (PS Plus) copies.
    var subscriptionPlatformIDs: [String]

    /// The format of the game's *sole* reformat-able copy (exactly one non-subscription,
    /// single-kind product — the set ``LibraryStore/changeCopyFormat(gameIDs:to:)`` acts
    /// on), or nil when the game has zero or several such copies. Lets a "Change Copy
    /// Format" menu show ✓/– without a DB round-trip (PLAN §13.3).
    var singleCopyFormat: ProductFormat?
    /// True when the game owns **several** reformat-able copies (≥ 2 non-subscription
    /// single copies) — the ambiguous set "Change Copy Format" skips (banner footer).
    var hasSeveralChangeableCopies: Bool

    /// A really-owned physical copy exists.
    var hasPhysical: Bool { !physicalPlatformIDs.isEmpty }
    /// A really-owned digital copy exists.
    var hasDigital: Bool { !digitalPlatformIDs.isEmpty }
    /// A subscription (PS Plus) claim exists — drives the PS Plus badge. A game with a
    /// real digital copy **and** a PS Plus claim shows both (PLAN §13.3).
    var hasSubscription: Bool { !subscriptionPlatformIDs.isEmpty }

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
        holdsUp: HoldsUp? = nil,
        hasROM: Bool = false,
        ownedOnlyViaSubscription: Bool = false,
        physicalPlatformIDs: [String] = [],
        digitalPlatformIDs: [String] = [],
        romPlatformIDs: [String] = [],
        subscriptionPlatformIDs: [String] = [],
        singleCopyFormat: ProductFormat? = nil,
        hasSeveralChangeableCopies: Bool = false
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
        self.holdsUp = holdsUp
        self.hasROM = hasROM
        self.ownedOnlyViaSubscription = ownedOnlyViaSubscription
        self.physicalPlatformIDs = physicalPlatformIDs
        self.digitalPlatformIDs = digitalPlatformIDs
        self.romPlatformIDs = romPlatformIDs
        self.subscriptionPlatformIDs = subscriptionPlatformIDs
        self.singleCopyFormat = singleCopyFormat
        self.hasSeveralChangeableCopies = hasSeveralChangeableCopies
    }

    /// Derived Backlog membership (PLAN §4 invariant 2): owned but not played.
    var isBacklog: Bool { owned && !played }

    /// A played game that has no tier yet ("Unranked" smart list).
    var isUnranked: Bool { played && tierID == nil }

    /// A played game with no "Holds up today?" mark yet — the "Needs a 'Holds Up' Rating"
    /// smart list (PLAN §7b/§8).
    var needsHoldsUpRating: Bool { played && holdsUp == nil }
}

#if DEBUG
extension GameSummary {
    /// Preview / sample data for SwiftUI previews and the Wave 0 smoke test.
    static let samples: [GameSummary] = [
        GameSummary(
            id: 1, title: "Bloodborne", year: 2015, coverFile: nil,
            tierID: 1, tierLetter: "S", tierColorHex: "#FF3B30", rankKey: 1000,
            played: true, owned: true, platformIDs: ["ps4"], status: .completed,
            physicalPlatformIDs: ["ps4"], singleCopyFormat: .physical
        ),
        GameSummary(
            id: 2, title: "Elden Ring", year: 2022,
            tierID: 1, tierLetter: "S", tierColorHex: "#FF3B30", rankKey: 2000,
            played: true, owned: true, platformIDs: ["ps5", "ps4"], status: .finished,
            digitalPlatformIDs: ["ps5"], subscriptionPlatformIDs: ["ps4"],
            singleCopyFormat: .digital
        ),
        GameSummary(
            id: 3, title: "Metal Gear Solid 3: Snake Eater", year: 2004,
            tierID: 2, tierLetter: "A", tierColorHex: "#FF9500", rankKey: 1500,
            played: true, owned: true, isCompilationMember: true,
            platformIDs: ["ps2"], status: .finished, hasROM: true,
            physicalPlatformIDs: ["ps2"], romPlatformIDs: ["ps2"],
            hasSeveralChangeableCopies: true
        ),
        GameSummary(
            id: 4, title: "Broken Sword", year: 1996,
            played: true, owned: false, platformIDs: ["pc"]
        ),
        GameSummary(
            id: 5, title: "Silksong", year: 2025,
            played: false, owned: true, platformIDs: ["ps5"],
            digitalPlatformIDs: ["ps5"], singleCopyFormat: .digital
        ),
    ]
}
#endif
