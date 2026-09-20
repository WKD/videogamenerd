import Foundation

/// Builds IGDB image-CDN URLs from a cover `image_id` (PLAN §5.2). IGDB serves a
/// fixed set of named sizes; the `t_…` token in the path selects one.
enum IGDBImageSize: String, Sendable, CaseIterable {
    case coverSmall = "t_cover_small"          // 90×128
    case coverBig = "t_cover_big"              // 264×374
    case coverBig2x = "t_cover_big_2x"         // 528×748  (PLAN default)
    case screenshotMed = "t_screenshot_med"
    case thumb = "t_thumb"                      // 90×90
    case p720 = "t_720p"
    case p1080 = "t_1080p"
}

enum IGDBImageURL {
    private static let base = "https://images.igdb.com/igdb/image/upload"

    /// Cover URL for an `image_id`. PLAN's default is `t_cover_big_2x`.
    static func cover(imageID: String, size: IGDBImageSize = .coverBig2x) -> URL? {
        URL(string: "\(base)/\(size.rawValue)/\(imageID).jpg")
    }

    /// Artwork / screenshot URL for an `image_id` (PLAN §5.2 "Choose Cover…"): the same
    /// image CDN, a large default token. Artworks are landscape and have no fixed size,
    /// so the token only scales — the true dimensions come from the IGDB query.
    static func artwork(imageID: String, size: IGDBImageSize = .p1080) -> URL? {
        URL(string: "\(base)/\(size.rawValue)/\(imageID).jpg")
    }
}
