import Foundation
import GRDB

/// Reads an old **Delicious Library 2** database (`.deliciouslibrary2`, a Core Data
/// SQLite store) **read-only and immutable** and returns plain ``DeliciousGame`` values
/// (PLAN §5.5, the first file-based importer).
///
/// Safety: the store is the owner's private catalogue (it also holds ~1 300 movies,
/// books, music and loan records). This reader
///  - opens with GRDB `Configuration.readonly` — no write, no `-wal`/`-journal` creation,
///    works on a file in a read-only folder (the DL2 store uses rollback-journal mode);
///  - resolves the `Medium` entity **by name** through `Z_PRIMARYKEY` (never hard-codes
///    the numeric `Z_ENT`), and reads only rows whose `ZTYPE = 'VideoGame'`;
///  - never selects the columns of non-game rows.
struct DeliciousLibraryReader: Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    /// The Core Data reference-date epoch: `TIMESTAMP` columns hold seconds since
    /// 2001-01-01, exactly Foundation's `timeIntervalSinceReferenceDate`.
    static func date(fromCoreData seconds: Double?) -> Date? {
        guard let seconds, seconds != 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return c
    }()

    static func year(fromCoreData seconds: Double?) -> Int? {
        guard let date = date(fromCoreData: seconds) else { return nil }
        return utcCalendar.component(.year, from: date)
    }

    // MARK: - Open (read-only, immutable)

    /// Open the store read-only. GRDB's `readonly` opens `SQLITE_OPEN_READONLY`, so no
    /// bytes are ever written; the DL2 store is rollback-journal, so no sidecar files are
    /// created either.
    func openReadOnly() throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.label = "DeliciousLibrary.ro"
        do {
            return try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw DeliciousImportError.cannotOpen(error.localizedDescription)
        }
    }

    // MARK: - Read games

    /// Validate the store and read every `VideoGame` medium. Throws
    /// ``DeliciousImportError`` on a non-Delicious file, an unknown schema, or an empty
    /// game list.
    func readGames() throws -> [DeliciousGame] {
        let queue = try openReadOnly()
        return try queue.read { db in
            try Self.validate(db)
            let mediumEnt = try Self.mediumEntityID(db)
            let games = try Self.fetchGames(db, mediumEnt: mediumEnt)
            guard !games.isEmpty else { throw DeliciousImportError.noVideoGames }
            return games
        }
    }

    /// Fetch the box-art JPEG blobs for a set of cover PKs in one pass (live cover
    /// fallback, PLAN §5.5). Missing / unreadable covers are simply absent from the map.
    func coverJPEGData(forCoverImagePKs pks: [Int64]) throws -> [Int64: Data] {
        guard !pks.isEmpty else { return [:] }
        let queue = try openReadOnly()
        return try queue.read { db in
            var out: [Int64: Data] = [:]
            for pk in Set(pks) {
                // LazyCoverImageData.ZCOVERIMAGE == CoverImage.Z_PK (the medium's ZCOVERIMAGE).
                if let data = try Data.fetchOne(db, sql: """
                    SELECT ZCOMPRESSEDIMAGEDATA FROM ZLAZYCOVERIMAGEDATA
                    WHERE ZCOVERIMAGE = ? AND ZCOMPRESSEDIMAGEDATA IS NOT NULL LIMIT 1
                    """, arguments: [pk]) {
                    out[pk] = data
                }
            }
            return out
        }
    }

    // MARK: - Validation

    static func validate(_ db: Database) throws {
        // Core Data marker tables + the owner's items table must exist.
        for table in ["Z_PRIMARYKEY", "ZABSTRACTAMAZONATTRIBUTESHOLDER"] {
            if try !db.tableExists(table) { throw DeliciousImportError.notDeliciousFile }
        }
        // The DL2 shape: the items table carries these columns.
        let columns = try Set(db.columns(in: "ZABSTRACTAMAZONATTRIBUTESHOLDER").map(\.name))
        for required in ["ZTYPE", "ZTITLE", "ZUUIDSTRING", "ZPLATFORMSCOMPOSITESTRING"] {
            if !columns.contains(required) { throw DeliciousImportError.unsupportedVersion }
        }
        // The `Medium` entity must be resolvable by name.
        if try entityID(named: "Medium", db) == nil { throw DeliciousImportError.unsupportedVersion }
    }

    /// Resolve an entity's numeric `Z_ENT` by its Core Data name (never hard-coded).
    static func entityID(named name: String, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = ?",
                           arguments: [name])
    }

    static func mediumEntityID(_ db: Database) throws -> Int64 {
        guard let ent = try entityID(named: "Medium", db) else {
            throw DeliciousImportError.unsupportedVersion
        }
        return ent
    }

    // MARK: - Rows

    private static func fetchGames(_ db: Database, mediumEnt: Int64) throws -> [DeliciousGame] {
        // Only owner-catalogued Medium rows of type VideoGame — never Amazon
        // recommendation/cache rows (other Z_ENT) or other media (other ZTYPE).
        let rows = try Row.fetchAll(db, sql: """
            SELECT ZUUIDSTRING, ZTITLE, ZPLATFORMSCOMPOSITESTRING, ZEAN, ZASIN,
                   ZPUBLISHDATE, ZCREATIONDATE, ZEDITIONSCOMPOSITESTRING,
                   ZFORMATSINGULARSTRING, ZCOUNTRYCODE, ZLOAN, ZCOVERIMAGE
            FROM ZABSTRACTAMAZONATTRIBUTESHOLDER
            WHERE Z_ENT = ? AND ZTYPE = 'VideoGame'
            ORDER BY ZTITLE COLLATE NOCASE
            """, arguments: [mediumEnt])
        return rows.compactMap(Self.game(from:))
    }

    static func game(from row: Row) -> DeliciousGame? {
        // A usable game needs a stable id and a title.
        guard let uuid = row["ZUUIDSTRING"] as String?, !uuid.isEmpty else { return nil }
        let title = (row["ZTITLE"] as String?) ?? ""
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let platforms = (row["ZPLATFORMSCOMPOSITESTRING"] as String?)
            .map(Self.splitComposite) ?? []
        return DeliciousGame(
            uuid: uuid,
            title: title,
            platforms: platforms,
            ean: nonEmpty(row["ZEAN"] as String?),
            asin: nonEmpty(row["ZASIN"] as String?),
            publishYear: year(fromCoreData: row["ZPUBLISHDATE"] as Double?),
            catalogedAt: date(fromCoreData: row["ZCREATIONDATE"] as Double?),
            editions: nonEmpty(row["ZEDITIONSCOMPOSITESTRING"] as String?),
            format: nonEmpty(row["ZFORMATSINGULARSTRING"] as String?),
            country: nonEmpty(row["ZCOUNTRYCODE"] as String?),
            wasLoaned: (row["ZLOAN"] as Int64?) != nil,
            coverImagePK: row["ZCOVERIMAGE"] as Int64?)
    }

    /// Split a Delicious "composite string" (newline-separated) into trimmed, non-empty
    /// parts in order.
    static func splitComposite(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
