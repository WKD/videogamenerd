import Foundation
import GRDB

/// GRDB record for the `products` table — a thing you own on one platform, a
/// single game or a compilation (PLAN §4). Ownership of member games is derived
/// from the existence of a product, so it is all-or-nothing by construction.
struct ProductRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Hashable, Identifiable {
    var id: Int64?
    var title: String?
    var platformID: String
    var kind: String                 // ProductKind rawValue
    var format: String               // ProductFormat rawValue
    var edition: String?
    var region: String?
    var igdbID: Int64?
    var coverFile: String?
    var source: String               // ProductSource rawValue
    var psnEntitlement: String?
    var acquiredAt: Date?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "products"

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case title
        case platformID = "platform_id"
        case kind
        case format
        case edition
        case region
        case igdbID = "igdb_id"
        case coverFile = "cover_file"
        case source
        case psnEntitlement = "psn_entitlement"
        case acquiredAt = "acquired_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    typealias Columns = CodingKeys

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    init(
        id: Int64? = nil,
        title: String? = nil,
        platformID: String,
        kind: ProductKind = .single,
        format: ProductFormat = .physical,
        edition: String? = nil,
        region: String? = nil,
        igdbID: Int64? = nil,
        coverFile: String? = nil,
        source: ProductSource = .manual,
        psnEntitlement: String? = nil,
        acquiredAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.platformID = platformID
        self.kind = kind.rawValue
        self.format = format.rawValue
        self.edition = edition
        self.region = region
        self.igdbID = igdbID
        self.coverFile = coverFile
        self.source = source.rawValue
        self.psnEntitlement = psnEntitlement
        self.acquiredAt = acquiredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
