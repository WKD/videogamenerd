import Foundation

/// One video-game row read from an old **Delicious Library 2** database
/// (`.deliciouslibrary2`, a Core Data SQLite store). A plain, Foundation-only value —
/// the reader never surfaces the store's non-game rows (movies / books / music / loans)
/// through this type (PLAN §5.5). Titles are Amazon FR/UK product names and are noisy;
/// ``DeliciousMapping`` does the cleaning for matching while the original is kept here.
struct DeliciousGame: Sendable, Hashable, Identifiable {
    /// `ZUUIDSTRING` — the stable id used as the import `external_id`.
    var uuid: String
    /// `ZTITLE` — the original, unmodified Amazon title (shown as-is in review).
    var title: String
    /// `ZPLATFORMSCOMPOSITESTRING` split on newlines, in file order (raw labels like
    /// "PlayStation 3", "Windows XP", "Mac OS X"); may be empty.
    var platforms: [String]
    /// `ZEAN` (barcode) — present on every game in the owner's file.
    var ean: String?
    /// `ZASIN` (Amazon id).
    var asin: String?
    /// Release year from `ZPUBLISHDATE` (Core Data epoch), or nil.
    var publishYear: Int?
    /// `ZCREATIONDATE` — when the item was catalogued (≈ acquired), or nil.
    var catalogedAt: Date?
    /// `ZEDITIONSCOMPOSITESTRING` — e.g. "Standard Edition"; nil/empty for most.
    var editions: String?
    /// `ZFORMATSINGULARSTRING` — physical media label ("Blu-ray", "Cartouche de jeu"…).
    var format: String?
    /// `ZCOUNTRYCODE` — "fr" / "gb".
    var country: String?
    /// True when the item carried a `ZLOAN` link (lent out) — shown only as a note.
    var wasLoaned: Bool
    /// `ZCOVERIMAGE` foreign key (→ `ZCOVERIMAGE.Z_PK`), used to fetch the box-art blob.
    var coverImagePK: Int64?

    var id: String { uuid }

    init(uuid: String, title: String, platforms: [String] = [], ean: String? = nil,
         asin: String? = nil, publishYear: Int? = nil, catalogedAt: Date? = nil,
         editions: String? = nil, format: String? = nil, country: String? = nil,
         wasLoaned: Bool = false, coverImagePK: Int64? = nil) {
        self.uuid = uuid
        self.title = title
        self.platforms = platforms
        self.ean = ean
        self.asin = asin
        self.publishYear = publishYear
        self.catalogedAt = catalogedAt
        self.editions = editions
        self.format = format
        self.country = country
        self.wasLoaned = wasLoaned
        self.coverImagePK = coverImagePK
    }
}
