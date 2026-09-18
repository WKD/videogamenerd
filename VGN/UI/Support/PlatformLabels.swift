import Foundation

/// Decodes the bundled `platforms.json` (owned by lane B) into `PlatformInfo`
/// value types, for UI labels/chips and previews. `PlatformInfo` is `Codable`
/// and its keys are a subset of the JSON's, so extra keys (`igdbIDs`,
/// `libretroRepo`) are ignored on decode.
///
/// Named `PlatformLabels` (not `PlatformCatalog`) to avoid colliding with the
/// services lane's own `PlatformCatalog` in the same module. This is a read-only
/// convenience for the UI; the live sidebar gets its in-use platforms from
/// `LibraryDataSource.platformsInUse()`.
enum PlatformLabels {
    /// Every platform in the catalog, in file order.
    static let all: [PlatformInfo] = {
        guard let url = Bundle.main.url(forResource: "platforms", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PlatformInfo].self, from: data)
        else { return [] }
        return decoded
    }()

    /// Slug → platform, for chip/label lookups.
    static let bySlug: [String: PlatformInfo] = {
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    /// Short label for a slug ("PS5"), falling back to the slug itself.
    static func short(_ slug: String) -> String { bySlug[slug]?.short ?? slug }

    /// Full info for a slug, if known.
    static func info(_ slug: String) -> PlatformInfo? { bySlug[slug] }
}
