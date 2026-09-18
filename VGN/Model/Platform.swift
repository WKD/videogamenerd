import Foundation

/// The kind of machine a platform is, used to group / present it (PLAN §5.6).
enum PlatformKind: String, Hashable, Sendable, Codable, CaseIterable {
    case console
    case handheld
    case computer
    case arcade
}

/// A platform as the UI needs it. The authoritative data lives in
/// `Resources/platforms.json` (lane B); this is the decoded value type the
/// sidebar and chips render. Identity is the slug (e.g. "ps5", "snes", "pc").
struct PlatformInfo: Hashable, Sendable, Identifiable, Codable {
    /// Slug id, e.g. `ps5`, `snes`, `pc`, `mac`.
    var id: String
    /// Full display name, e.g. "PlayStation 5".
    var name: String
    /// Short label for chips, e.g. "PS5".
    var short: String
    /// Manufacturer used for the sidebar grouping, e.g. "Sony", "Nintendo".
    var manufacturer: String
    var kind: PlatformKind
    /// Hardware generation, when meaningful (nil for computers/arcade).
    var generation: Int?
    /// Sort order within its manufacturer group.
    var sort: Int

    init(
        id: String,
        name: String,
        short: String,
        manufacturer: String,
        kind: PlatformKind,
        generation: Int? = nil,
        sort: Int = 0
    ) {
        self.id = id
        self.name = name
        self.short = short
        self.manufacturer = manufacturer
        self.kind = kind
        self.generation = generation
        self.sort = sort
    }
}
