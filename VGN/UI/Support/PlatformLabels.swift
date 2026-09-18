import Foundation

/// UI labels/chips/previews for platforms, read from the one shared
/// ``PlatformCatalog`` model (which decodes the bundled `platforms.json`). A
/// read-only convenience for the UI; the live sidebar gets its in-use platforms
/// from `LibraryDataSource.platformsInUse()`.
enum PlatformLabels {
    /// Every platform in the catalog, in file order.
    static let all: [PlatformInfo] = (try? PlatformCatalog.loadFromBundle())?.platformInfos ?? []

    /// Slug → platform, for chip/label lookups.
    static let bySlug: [String: PlatformInfo] = {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// Short label for a slug ("PS5"), falling back to the slug itself.
    static func short(_ slug: String) -> String { bySlug[slug]?.short ?? slug }

    /// Full info for a slug, if known.
    static func info(_ slug: String) -> PlatformInfo? { bySlug[slug] }
}
