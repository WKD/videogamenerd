import Foundation
import GRDB

/// GRDB record for the `platforms` table. The authoritative data is the bundled
/// `platforms.json`; this persists it (incl. `igdb_ids` as a JSON array and
/// `libretro_repo`) so the services lane can resolve platforms without touching
/// the file. Maps to the Foundation-only ``PlatformInfo`` for the UI.
struct PlatformRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    var id: String                   // slug
    var name: String
    var short: String
    var manufacturer: String
    var group: String                // sidebar section
    var kind: String
    var generation: Int?
    var igdbIDsJSON: String          // JSON array of Int
    var libretroRepo: String?
    var sort: Int

    static let databaseTableName = "platforms"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case name
        case short
        case manufacturer
        case group = "group_name"
        case kind
        case generation
        case igdbIDsJSON = "igdb_ids"
        case libretroRepo = "libretro_repo"
        case sort
    }

    typealias Columns = CodingKeys

    /// IGDB platform ids decoded from the stored JSON array.
    var igdbIDs: [Int] {
        (try? JSONDecoder().decode([Int].self, from: Data(igdbIDsJSON.utf8))) ?? []
    }

    /// The Foundation-only value type the UI consumes.
    var info: PlatformInfo {
        PlatformInfo(
            id: id,
            name: name,
            short: short,
            manufacturer: manufacturer,
            group: group,
            kind: PlatformKind(rawValue: kind) ?? .console,
            generation: generation,
            sort: sort
        )
    }
}
