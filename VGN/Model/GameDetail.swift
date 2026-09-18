import Foundation

/// The rich value type the inspector renders for a single game (PLAN §8).
/// Everything the detail pane shows: metadata, genres, owned copies (with their
/// platform / format / edition and any "part of compilation X" context),
/// played/status, tier/rank, and playtime + time-to-beat.
///
/// Foundation-only (like the rest of `VGN/Model/`). Lane A's `gameDetail(id:)`
/// builds it; the UI consumes only this.
struct GameDetail: Sendable, Hashable, Identifiable {
    var id: Int64
    var igdbID: Int64?
    var title: String
    var sortTitle: String
    var summary: String?
    var releaseDate: Date?
    var year: Int?
    var decade: Int?

    var played: Bool
    var owned: Bool
    var status: PlayStatus?

    var tierID: Int64?
    var tierLetter: String?
    var tierLabel: String?
    var tierColorHex: String?
    var rankKey: RankKey?

    var coverFile: String?
    var igdbCoverImageID: String?
    /// True when the user set this cover by hand (drop / choose). Background
    /// enrichment never replaces it, and the inspector offers "Remove custom
    /// cover" (PLAN §5.2 point 4 / §7b `user_edited`).
    var userEditedCover: Bool = false

    var genres: [String]
    var platformIDs: [String]

    var myPlaytimeS: Int?
    var psnPlaytimeS: Int?
    var ttbHastilyS: Int?
    var ttbNormallyS: Int?
    var ttbCompletelyS: Int?
    var ttbSource: String?

    var addedAt: Date
    var updatedAt: Date

    /// Every product this game belongs to (owned copies). A copy whose product
    /// has more than one member is a compilation membership.
    var copies: [Copy]

    /// True when this game is a member of at least one compilation product.
    var isCompilationMember: Bool { copies.contains { $0.memberCount > 1 } }

    /// The effective playtime shown to the user: manual value wins over PSN
    /// (PLAN §6.4).
    var effectivePlaytimeS: Int? { myPlaytimeS ?? psnPlaytimeS }

    /// A game that is played but has no tier ("Unranked" — PLAN §8).
    var isUnranked: Bool { played && tierID == nil }

    /// A played, tiered game with no fine-rank position yet (duel queue).
    var isUnplaced: Bool { played && tierID != nil && rankKey == nil }

    /// One owned copy of this game — a row in a product.
    struct Copy: Sendable, Hashable, Identifiable {
        var productID: Int64
        var id: Int64 { productID }
        var platformID: String
        var format: ProductFormat
        var kind: ProductKind
        /// The product's own title (e.g. a compilation's name), if any.
        var title: String?
        var edition: String?
        var region: String?
        var source: ProductSource
        /// This game's 0-based position within the product.
        var position: Int
        /// Total number of games in the product (> 1 ⇒ compilation).
        var memberCount: Int
        /// Titles of **all** member games of the product, in position order (only
        /// populated for a compilation copy, `memberCount > 1`). Lets the inspector
        /// and the copy-removal sheet name every game the all-or-nothing ownership
        /// affects, without a second async read (PLAN §8).
        var memberTitles: [String] = []
        /// Member game ids, parallel to ``memberTitles`` (so a member row can select
        /// the game it names). Empty for a single-game copy.
        var memberIDs: [Int64] = []

        var isCompilation: Bool { kind == .compilation || memberCount > 1 }

        init(
            productID: Int64,
            platformID: String,
            format: ProductFormat,
            kind: ProductKind,
            title: String? = nil,
            edition: String? = nil,
            region: String? = nil,
            source: ProductSource,
            position: Int,
            memberCount: Int,
            memberTitles: [String] = [],
            memberIDs: [Int64] = []
        ) {
            self.productID = productID
            self.platformID = platformID
            self.format = format
            self.kind = kind
            self.title = title
            self.edition = edition
            self.region = region
            self.source = source
            self.position = position
            self.memberCount = memberCount
            self.memberTitles = memberTitles
            self.memberIDs = memberIDs
        }
    }
}
