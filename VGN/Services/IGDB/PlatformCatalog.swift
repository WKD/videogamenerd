import Foundation

/// One row of `VGN/Resources/platforms.json`. Fields per docs/EXECUTION.md §Shared.
/// This is a *services-side* decoder used to map IGDB platform ids → VGN slugs and to
/// look up a platform's libretro repo. The Database lane has its own seed decoder for
/// the same file; the orchestrator should dedupe these into one next wave (noted in
/// the handoff).
struct PlatformCatalogEntry: Decodable, Sendable, Equatable {
    let id: String              // slug
    let name: String
    let short: String
    let manufacturer: String
    let group: String
    let kind: String
    let generation: Int?
    let igdbIDs: [Int]
    let libretroRepo: String?
    let sort: Int
}

/// In-memory index over the platform catalogue. Cheap to build; construct once and
/// share. Injectable for tests (pass entries directly); the default loads the bundled
/// JSON.
struct PlatformCatalog: Sendable {
    let entries: [PlatformCatalogEntry]
    private let slugByIGDBID: [Int: String]
    private let entryBySlug: [String: PlatformCatalogEntry]

    init(entries: [PlatformCatalogEntry]) {
        self.entries = entries
        var slugByIGDBID: [Int: String] = [:]
        var entryBySlug: [String: PlatformCatalogEntry] = [:]
        for entry in entries {
            entryBySlug[entry.id] = entry
            for igdbID in entry.igdbIDs where slugByIGDBID[igdbID] == nil {
                slugByIGDBID[igdbID] = entry.id
            }
        }
        self.slugByIGDBID = slugByIGDBID
        self.entryBySlug = entryBySlug
    }

    /// VGN slug for an IGDB platform id, or `nil` if that platform is not catalogued.
    func slug(forIGDBID igdbID: Int) -> String? { slugByIGDBID[igdbID] }

    /// Map a list of IGDB platform ids to VGN slugs, deduped, preserving first-seen
    /// order.
    func slugs(forIGDBIDs igdbIDs: [Int]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in igdbIDs {
            guard let slug = slugByIGDBID[id], !seen.contains(slug) else { continue }
            seen.insert(slug)
            out.append(slug)
        }
        return out
    }

    func entry(forSlug slug: String) -> PlatformCatalogEntry? { entryBySlug[slug] }

    /// libretro-thumbnails repo for a VGN platform slug (nil = no retro repo).
    func libretroRepo(forSlug slug: String) -> String? { entryBySlug[slug]?.libretroRepo }

    // MARK: - Loading

    enum LoadError: Error, Sendable { case resourceMissing }

    /// Decode a catalogue from raw JSON bytes.
    static func load(from data: Data) throws -> PlatformCatalog {
        let entries = try JSONDecoder().decode([PlatformCatalogEntry].self, from: data)
        return PlatformCatalog(entries: entries)
    }

    /// Load from the app bundle's `platforms.json`. Hosted test bundles see the app
    /// as `Bundle.main`, so this also works under test.
    static func loadFromBundle(_ bundle: Bundle = .main) throws -> PlatformCatalog {
        guard let url = bundle.url(forResource: "platforms", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        return try load(from: try Data(contentsOf: url))
    }
}
