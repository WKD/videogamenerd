import Foundation

/// One row of `VGN/Resources/platforms.json` (fields per docs/EXECUTION.md
/// §Shared: `id, name, short, manufacturer, group, kind, generation?, igdbIDs,
/// libretroRepo?, sort`).
///
/// This is the **single** Foundation-only decoded model for the platform
/// catalogue — the DB seed, the services layer (IGDB id → slug, libretro repo)
/// and the UI labels all read from it. It replaces the three former decoders
/// (`PlatformSeed`, the services `PlatformCatalogEntry`, and `PlatformLabels`'s
/// direct `PlatformInfo` decode).
struct PlatformCatalogEntry: Codable, Sendable, Equatable {
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

    /// The `kind` string as the typed enum (defaults to `.console`).
    var kindEnum: PlatformKind { PlatformKind(rawValue: kind) ?? .console }

    /// The Foundation-only value type the UI consumes (chips, labels, previews).
    var info: PlatformInfo {
        PlatformInfo(
            id: id, name: name, short: short, manufacturer: manufacturer,
            group: group, kind: kindEnum, generation: generation, sort: sort
        )
    }
}

/// In-memory index over the platform catalogue. Cheap to build; construct once
/// and share. Injectable for tests (pass entries directly); the default loads the
/// bundled JSON.
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

    /// The catalogue as UI value types, in file order.
    var platformInfos: [PlatformInfo] { entries.map(\.info) }

    // MARK: - Loading

    enum LoadError: Error, Sendable { case resourceMissing }

    /// Decode a catalogue from raw JSON bytes.
    static func load(from data: Data) throws -> PlatformCatalog {
        PlatformCatalog(entries: try decodeEntries(from: data))
    }

    /// Decode just the entries (the DB seed maps these straight to records).
    static func decodeEntries(from data: Data) throws -> [PlatformCatalogEntry] {
        try JSONDecoder().decode([PlatformCatalogEntry].self, from: data)
    }

    /// Load from the app bundle's `platforms.json`. Hosted test bundles see the app
    /// as `Bundle.main`, so this also works under test.
    static func loadFromBundle(_ bundle: Bundle = .main) throws -> PlatformCatalog {
        PlatformCatalog(entries: try entriesFromBundle(bundle))
    }

    /// The bundled catalogue's entries.
    static func entriesFromBundle(_ bundle: Bundle = .main) throws -> [PlatformCatalogEntry] {
        guard let url = bundle.url(forResource: "platforms", withExtension: "json") else {
            throw LoadError.resourceMissing
        }
        return try decodeEntries(from: try Data(contentsOf: url))
    }
}
