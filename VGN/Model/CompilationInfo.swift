import Foundation

/// One member game of a compilation product, as the compilation editor and the
/// inspector's "Part of …" list render it (PLAN §5.1/§8). Foundation-only value
/// type; Lane A builds it from `product_games ⋈ games`.
struct CompilationMemberInfo: Sendable, Hashable, Identifiable {
    var gameID: Int64
    var id: Int64 { gameID }
    var title: String
    /// 0-based position within the product.
    var position: Int
    var year: Int?
    var played: Bool
    /// The member's own tier letter, if tiered (members keep their own tier/rank).
    var tierLetter: String?
    var coverFile: String?

    init(
        gameID: Int64,
        title: String,
        position: Int,
        year: Int? = nil,
        played: Bool = false,
        tierLetter: String? = nil,
        coverFile: String? = nil
    ) {
        self.gameID = gameID
        self.title = title
        self.position = position
        self.year = year
        self.played = played
        self.tierLetter = tierLetter
        self.coverFile = coverFile
    }
}

/// A whole compilation product plus its ordered members — everything the
/// compilation editor loads (PLAN §5.1). Foundation-only.
struct CompilationProductInfo: Sendable, Hashable, Identifiable {
    var id: Int64
    var title: String?
    var platformID: String
    var format: ProductFormat
    var kind: ProductKind
    var edition: String?
    var region: String?
    var igdbID: Int64?
    var members: [CompilationMemberInfo]

    init(
        id: Int64,
        title: String? = nil,
        platformID: String,
        format: ProductFormat = .physical,
        kind: ProductKind = .compilation,
        edition: String? = nil,
        region: String? = nil,
        igdbID: Int64? = nil,
        members: [CompilationMemberInfo] = []
    ) {
        self.id = id
        self.title = title
        self.platformID = platformID
        self.format = format
        self.kind = kind
        self.edition = edition
        self.region = region
        self.igdbID = igdbID
        self.members = members
    }
}
