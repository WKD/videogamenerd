import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
@testable import VGN

/// Builds a **synthetic** Delicious Library 2 store on disk for tests — never the owner's
/// real file. Creates just the Core Data tables/columns the reader reads, a
/// `Z_PRIMARYKEY` with **shuffled** entity ids (so the by-name `Medium` lookup is proven,
/// not a hard-coded 6), game rows, non-game rows, non-Medium rows that must be ignored,
/// and (optionally) a cover blob.
enum DeliciousTestStore {
    /// Entity ids are deliberately NOT the real DL2 numbers, to prove name resolution.
    static let mediumEnt: Int64 = 42
    static let recommendationEnt: Int64 = 17
    static let coverImageEnt: Int64 = 8
    static let lazyEnt: Int64 = 9
    static let loanEnt: Int64 = 11

    struct GameSpec {
        var uuid: String
        var title: String
        var platforms: [String]
        var ean: String?
        var asin: String?
        var publishSeconds: Double?
        var creationSeconds: Double?
        var editions: String?
        var format: String?
        var country: String?
        var loanPK: Int64?
        var coverPK: Int64?
        var coverJPEG: Data?

        init(uuid: String, title: String, platforms: [String] = [], ean: String? = "0000000000000",
             asin: String? = nil, publishSeconds: Double? = nil, creationSeconds: Double? = nil,
             editions: String? = nil, format: String? = "DVD", country: String? = "fr",
             loanPK: Int64? = nil, coverPK: Int64? = nil, coverJPEG: Data? = nil) {
            self.uuid = uuid; self.title = title; self.platforms = platforms
            self.ean = ean; self.asin = asin; self.publishSeconds = publishSeconds
            self.creationSeconds = creationSeconds; self.editions = editions
            self.format = format; self.country = country; self.loanPK = loanPK
            self.coverPK = coverPK; self.coverJPEG = coverJPEG
        }
    }

    /// A well-formed store with the given VideoGame rows, plus noise rows (a movie, a
    /// book, and a non-Medium recommendation of type VideoGame) that must be ignored.
    /// Returns the file URL (caller cleans up its parent dir).
    static func make(_ games: [GameSpec], includeNoise: Bool = true) throws -> URL {
        let url = try freshFileURL()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try createSchema(db)
                try seedPrimaryKey(db)
                for (index, game) in games.enumerated() {
                    try insertGame(game, basePK: Int64(2000 + index * 10), db: db)
                }
                if includeNoise { try insertNoise(db) }
            }
            // Release the writer so no -wal/-journal lingers before the read-only open.
        }
        return url
    }

    /// A store missing the DL2 shape (Core Data tables present but the items table lacks
    /// `ZTYPE`) → `unsupportedVersion`.
    static func makeUnsupported() throws -> URL {
        let url = try freshFileURL()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in
                try db.execute(sql: "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME VARCHAR);")
                try db.execute(sql: """
                    CREATE TABLE ZABSTRACTAMAZONATTRIBUTESHOLDER (
                        Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE VARCHAR);
                    """)
            }
        }
        return url
    }

    /// A file that is not a Delicious store at all (no Core Data tables) → `notDeliciousFile`.
    static func makeForeign() throws -> URL {
        let url = try freshFileURL()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try queue.write { db in try db.execute(sql: "CREATE TABLE hello (x INTEGER);") }
        }
        return url
    }

    // MARK: - Schema

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: "CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);")
        try db.execute(sql: """
            CREATE TABLE ZABSTRACTAMAZONATTRIBUTESHOLDER (
                Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
                ZLOAN INTEGER, ZCOVERIMAGE INTEGER,
                ZPUBLISHDATE TIMESTAMP, ZPURCHASEDATE TIMESTAMP, ZCREATIONDATE TIMESTAMP,
                ZPLATFORMSCOMPOSITESTRING VARCHAR, ZUUIDSTRING VARCHAR, ZASIN VARCHAR,
                ZTITLE VARCHAR, ZEAN VARCHAR, ZCOUNTRYCODE VARCHAR, ZTYPE VARCHAR,
                ZFORMATSINGULARSTRING VARCHAR, ZEDITIONSCOMPOSITESTRING VARCHAR);
            """)
        try db.execute(sql: """
            CREATE TABLE ZLAZYCOVERIMAGEDATA (
                Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
                ZCOVERIMAGE INTEGER, ZCOMPRESSEDIMAGEDATA BLOB);
            """)
    }

    private static func seedPrimaryKey(_ db: Database) throws {
        let rows: [(Int64, String)] = [
            (recommendationEnt, "Recommendation"), (coverImageEnt, "CoverImage"),
            (lazyEnt, "LazyCoverImageData"), (loanEnt, "Loan"), (mediumEnt, "Medium"),
        ]
        for (ent, name) in rows {
            try db.execute(sql: "INSERT INTO Z_PRIMARYKEY (Z_ENT, Z_NAME, Z_MAX) VALUES (?, ?, 0)",
                           arguments: [ent, name])
        }
    }

    private static func insertGame(_ g: GameSpec, basePK: Int64, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO ZABSTRACTAMAZONATTRIBUTESHOLDER
                (Z_PK, Z_ENT, ZTYPE, ZUUIDSTRING, ZTITLE, ZPLATFORMSCOMPOSITESTRING,
                 ZEAN, ZASIN, ZPUBLISHDATE, ZCREATIONDATE, ZEDITIONSCOMPOSITESTRING,
                 ZFORMATSINGULARSTRING, ZCOUNTRYCODE, ZLOAN, ZCOVERIMAGE)
            VALUES (?, ?, 'VideoGame', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                basePK, mediumEnt, g.uuid, g.title, g.platforms.joined(separator: "\n"),
                g.ean, g.asin, g.publishSeconds, g.creationSeconds, g.editions,
                g.format, g.country, g.loanPK, g.coverPK])
        if let coverPK = g.coverPK, let jpeg = g.coverJPEG {
            try db.execute(sql: """
                INSERT INTO ZLAZYCOVERIMAGEDATA (Z_PK, Z_ENT, ZCOVERIMAGE, ZCOMPRESSEDIMAGEDATA)
                VALUES (?, ?, ?, ?)
                """, arguments: [basePK + 1, lazyEnt, coverPK, jpeg])
        }
    }

    private static func insertNoise(_ db: Database) throws {
        // A movie + a book on the Medium entity (wrong ZTYPE) and a Recommendation of
        // type VideoGame (wrong entity) — all must be skipped.
        try db.execute(sql: """
            INSERT INTO ZABSTRACTAMAZONATTRIBUTESHOLDER (Z_PK, Z_ENT, ZTYPE, ZUUIDSTRING, ZTITLE)
            VALUES (9001, ?, 'Movie', 'movie-uuid', 'A Private Movie'),
                   (9002, ?, 'Book',  'book-uuid',  'A Private Book'),
                   (9003, ?, 'VideoGame', 'rec-uuid', 'Amazon Recommendation')
            """, arguments: [mediumEnt, mediumEnt, recommendationEnt])
    }

    // MARK: - Files / covers

    private static func freshFileURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DL2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Delicious Library Items.deliciouslibrary2")
    }

    /// A small, valid JPEG (used for the cover-decode test).
    static func tinyJPEG() -> Data {
        let width = 4, height = 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
