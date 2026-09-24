import Foundation
import GRDB

/// Exports the whole library (PLAN §9 Safety — "JSON/CSV export … years of
/// curation"). Two products, both read from one consistent transaction:
///
///  - ``exportJSON(prettyPrinted:)`` — a complete, **re-importable** document:
///    tiers, games (with played/status/tier/rank, playtime, cover, ratings,
///    per-platform played flags, genres and IGDB traits), products with their
///    ordered memberships, and the full comparison log. Stable row ids are kept so
///    the relational graph (compilations, ranks, duels) survives a round-trip.
///  - ``exportCSV()`` — a flat, spreadsheet-friendly sheet, one row per game, with
///    the derived 1–10 score and overall rank computed from the ranking snapshot.
///
/// A `Sendable` thin value over ``AppDatabase``, mirroring ``LibraryStore``.
struct LibraryExporter: Sendable {
    let database: AppDatabase
    var dbReader: any DatabaseReader { database.dbWriter }

    init(_ database: AppDatabase) { self.database = database }

    static let formatIdentifier = "vgn.library"
    static let formatVersion = 1

    // MARK: - JSON

    func exportJSON(prettyPrinted: Bool = true) async throws -> Data {
        let document = try await dbReader.read { db in try Self.buildDocument(db) }
        return try Self.encodeJSON(document, prettyPrinted: prettyPrinted)
    }

    static func encodeJSON(_ document: Document, prettyPrinted: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    // MARK: - CSV

    func exportCSV() async throws -> String {
        try await dbReader.read { db in try Self.buildCSV(db) }
    }

    // MARK: - Codable document

    struct Document: Codable, Sendable, Equatable {
        var format: String
        var version: Int
        var exportedAt: Date
        var tiers: [Tier]
        var games: [Game]
        var products: [Product]
        var comparisons: [Comparison]
    }

    struct Tier: Codable, Sendable, Equatable {
        var id: Int64
        var letter: String
        var label: String
        var color: String
        var sort: Int
    }

    struct GamePlatform: Codable, Sendable, Equatable {
        var platformID: String
        var played: Bool
    }

    struct Trait: Codable, Sendable, Equatable {
        var kind: String
        var value: String
    }

    struct Game: Codable, Sendable, Equatable {
        var id: Int64
        var igdbID: Int64?
        var title: String
        var sortTitle: String
        var altTitles: [String]
        var summary: String?
        var releaseDate: Date?
        var year: Int?
        var played: Bool
        var status: String?
        /// The "To Revisit" flag (v15): with `status == "abandoned"`, `true` means the owner
        /// wants to come back to it. Additive; raw `status` keeps the four legacy values.
        var revisit: Bool
        /// "Holds up today?" (v16): `"holds_up"` / `"of_its_time"` / `"too_archaic"`, or nil =
        /// unrated. Optional so an export written before v16 still decodes (absent ⇒ unrated).
        var holdsUp: String?
        var tierID: Int64?
        var rankKey: Int64?
        var myPlaytimeS: Int?
        var psnPlaytimeS: Int?
        /// Batocera's own play time (v17). Additive; absent in older exports.
        var batoceraPlaytimeS: Int?
        var ttbHastilyS: Int?
        var ttbNormallyS: Int?
        var ttbCompletelyS: Int?
        var ttbSource: String?
        var igdbCoverImageID: String?
        var coverFile: String?
        var igdbRating: Double?
        var igdbRatingCount: Int?
        var userEdited: String
        /// HowLongToBeat game id, when the HLTB fallback filled an estimate (v6).
        var hltbID: Int64?
        /// How the game entered the library (v6, debugging). See ``GameOrigin``.
        var origin: String?
        /// Earliest / latest known play date, importer-filled (v9, PLAN §13.3).
        var firstPlayedAt: Date?
        var lastPlayedAt: Date?
        var addedAt: Date
        var updatedAt: Date
        var platforms: [GamePlatform]
        var genres: [String]
        var traits: [Trait]
    }

    struct Product: Codable, Sendable, Equatable {
        struct Member: Codable, Sendable, Equatable {
            var gameID: Int64
            var position: Int
        }
        var id: Int64
        var title: String?
        var platformID: String
        var kind: String
        var format: String
        var edition: String?
        var region: String?
        var igdbID: Int64?
        var coverFile: String?
        var source: String
        /// The importer's external id for this owned copy (idempotency key, v5).
        var externalID: String?
        var psnEntitlement: String?
        /// Subscription licence for this copy, or nil = really owned (v8, PLAN §13.3).
        /// `'ps_plus'` for a PS Plus claim — carried so a round-trip keeps the flag.
        var subscription: String?
        var acquiredAt: Date?
        var members: [Member]
    }

    struct Comparison: Codable, Sendable, Equatable {
        var winnerID: Int64
        var loserID: Int64
        var context: String
        var createdAt: Date
    }

    // MARK: - Building (one grouped pass each — no N+1)

    static func buildDocument(_ db: Database) throws -> Document {
        let tiers = try Row.fetchAll(db, sql: "SELECT id, letter, label, color, sort FROM tiers ORDER BY sort, id")
            .map { r in Tier(id: r["id"], letter: r["letter"], label: r["label"],
                             color: r["color"], sort: r["sort"]) }

        // Grouped child rows.
        var platformsByGame: [Int64: [GamePlatform]] = [:]
        for r in try Row.fetchAll(db, sql:
            "SELECT game_id, platform_id, played FROM game_platforms ORDER BY game_id, platform_id") {
            platformsByGame[r["game_id"], default: []].append(
                GamePlatform(platformID: r["platform_id"], played: r["played"]))
        }
        var genresByGame: [Int64: [String]] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT gg.game_id AS gid, ge.name AS name FROM game_genres gg
            JOIN genres ge ON ge.id = gg.genre_id ORDER BY gg.game_id, ge.name
            """) {
            genresByGame[r["gid"], default: []].append(r["name"])
        }
        var traitsByGame: [Int64: [Trait]] = [:]
        for r in try Row.fetchAll(db, sql:
            "SELECT game_id, kind, value FROM game_traits ORDER BY game_id, kind, value") {
            traitsByGame[r["game_id"], default: []].append(Trait(kind: r["kind"], value: r["value"]))
        }
        var membersByProduct: [Int64: [Product.Member]] = [:]
        for r in try Row.fetchAll(db, sql:
            "SELECT product_id, game_id, position FROM product_games ORDER BY product_id, position, game_id") {
            membersByProduct[r["product_id"], default: []].append(
                Product.Member(gameID: r["game_id"], position: r["position"]))
        }

        let games = try Row.fetchAll(db, sql: """
            SELECT id, igdb_id, title, sort_title, alt_titles, summary, release_date, year,
                   played, status, revisit, holds_up, tier_id, rank_key, my_playtime_s, psn_playtime_s,
                   batocera_playtime_s,
                   ttb_hastily_s, ttb_normally_s, ttb_completely_s, ttb_source,
                   igdb_cover_image_id, cover_file, igdb_rating, igdb_rating_count,
                   user_edited, hltb_id, origin, first_played_at, last_played_at,
                   added_at, updated_at
            FROM games ORDER BY id
            """).map { r -> Game in
            let altRaw: String = r["alt_titles"]
            let id: Int64 = r["id"]
            return Game(
                id: id, igdbID: r["igdb_id"], title: r["title"], sortTitle: r["sort_title"],
                altTitles: altRaw.split(separator: "\n").map(String.init),
                summary: r["summary"], releaseDate: r["release_date"], year: r["year"],
                played: r["played"], status: r["status"], revisit: r["revisit"],
                holdsUp: r["holds_up"],
                tierID: r["tier_id"], rankKey: r["rank_key"],
                myPlaytimeS: r["my_playtime_s"], psnPlaytimeS: r["psn_playtime_s"],
                batoceraPlaytimeS: r["batocera_playtime_s"],
                ttbHastilyS: r["ttb_hastily_s"], ttbNormallyS: r["ttb_normally_s"],
                ttbCompletelyS: r["ttb_completely_s"], ttbSource: r["ttb_source"],
                igdbCoverImageID: r["igdb_cover_image_id"], coverFile: r["cover_file"],
                igdbRating: r["igdb_rating"], igdbRatingCount: r["igdb_rating_count"],
                userEdited: r["user_edited"], hltbID: r["hltb_id"], origin: r["origin"],
                firstPlayedAt: r["first_played_at"], lastPlayedAt: r["last_played_at"],
                addedAt: r["added_at"], updatedAt: r["updated_at"],
                platforms: platformsByGame[id] ?? [], genres: genresByGame[id] ?? [],
                traits: traitsByGame[id] ?? [])
        }

        let products = try Row.fetchAll(db, sql: """
            SELECT id, title, platform_id, kind, format, edition, region, igdb_id,
                   cover_file, source, external_id, psn_entitlement, subscription, acquired_at
            FROM products ORDER BY id
            """).map { r -> Product in
            let id: Int64 = r["id"]
            return Product(
                id: id, title: r["title"], platformID: r["platform_id"], kind: r["kind"],
                format: r["format"], edition: r["edition"], region: r["region"], igdbID: r["igdb_id"],
                coverFile: r["cover_file"], source: r["source"], externalID: r["external_id"],
                psnEntitlement: r["psn_entitlement"], subscription: r["subscription"],
                acquiredAt: r["acquired_at"], members: membersByProduct[id] ?? [])
        }

        let comparisons = try Row.fetchAll(db, sql:
            "SELECT winner_id, loser_id, context, created_at FROM comparisons ORDER BY created_at, id")
            .map { r in Comparison(winnerID: r["winner_id"], loserID: r["loser_id"],
                                   context: r["context"], createdAt: r["created_at"]) }

        return Document(
            format: formatIdentifier, version: formatVersion, exportedAt: Date(),
            tiers: tiers, games: games, products: products, comparisons: comparisons)
    }

    // MARK: - CSV

    static let csvHeader = [
        "title", "year", "platforms", "owned", "played", "status", "revisit", "tier",
        "overall_rank", "score", "my_playtime_hours", "igdb_main_hours",
        "igdb_rating", "formats", "compilation", "origin", "last_played", "holds_up",
        "batocera_playtime_hours",
    ]

    /// ISO-8601 (date only) formatter for the CSV `last_played` column. Read-only after
    /// configuration; `ISO8601DateFormatter` is thread-safe for formatting.
    nonisolated(unsafe) static let csvDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func buildCSV(_ db: Database) throws -> String {
        // Ranking snapshot for derived score + overall rank.
        let snapshot = try RankingStore.loadSnapshot(db)
        let scores = DerivedScore.scores(snapshot)
        var rankByID: [Int64: Int] = [:]
        for row in GlobalRank.chart(snapshot) { rankByID[row.id] = row.position }
        var tierLetter: [Int64: String] = [:]
        for r in try Row.fetchAll(db, sql: "SELECT id, letter FROM tiers") { tierLetter[r["id"]] = r["letter"] }

        // Per-game platforms — the ONE effective-platform rule (PLAN §4), i.e. exactly what
        // the grid/inspector show — formats, ownership, compilation membership; grouped, no N+1.
        var platformsByGame: [Int64: Set<String>] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT game_id AS gid, platform_id AS pid FROM (\(LibraryQuery.effectivePlatformsSQL))
            """) {
            platformsByGame[r["gid"], default: []].insert(r["pid"])
        }
        var formatsByGame: [Int64: Set<String>] = [:]
        var ownedGames: Set<Int64> = []
        var compilationByGame: [Int64: String] = [:]
        for r in try Row.fetchAll(db, sql: """
            SELECT pg.game_id AS gid, p.format AS format, p.kind AS kind, p.title AS title
            FROM product_games pg JOIN products p ON p.id = pg.product_id
            """) {
            let gid: Int64 = r["gid"]
            ownedGames.insert(gid)
            formatsByGame[gid, default: []].insert(r["format"])
            if (r["kind"] as String) == "compilation" {
                compilationByGame[gid] = (r["title"] as String?) ?? ""
            }
        }

        var lines: [String] = [csvHeader.map(escapeCSV).joined(separator: ",")]
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title, year, played, status, revisit, holds_up, tier_id,
                   \(LibraryQuery.effectivePlaytimeSQL(alias: nil)) AS effective_playtime_s,
                   batocera_playtime_s, ttb_normally_s, igdb_rating, origin,
                   last_played_at
            FROM games ORDER BY sort_title, id
            """)
        for r in rows {
            let id: Int64 = r["id"]
            let played: Bool = r["played"]
            let tierID: Int64? = r["tier_id"]
            let platforms = (platformsByGame[id] ?? []).sorted().joined(separator: "|")
            let formats = ProductFormat.allCases
                .filter { (formatsByGame[id] ?? []).contains($0.rawValue) }
                .map(\.rawValue).joined(separator: "|")
            // Effective play time: manual, else max(PSN, Batocera) — never summed (v17).
            let myPlay: Int? = r["effective_playtime_s"]
            let field: [String] = [
                r["title"],
                (r["year"] as Int?).map(String.init) ?? "",
                platforms,
                ownedGames.contains(id) ? "yes" : "no",
                played ? "yes" : "no",
                (r["status"] as String?) ?? "",
                (r["revisit"] as Int64?) == 1 ? "yes" : "no",
                tierID.flatMap { tierLetter[$0] } ?? "",
                rankByID[id].map(String.init) ?? "",
                scores[id]?.csvString ?? "",
                myPlay.map { hours(fromSeconds: $0) } ?? "",
                (r["ttb_normally_s"] as Int?).map { hours(fromSeconds: $0) } ?? "",
                (r["igdb_rating"] as Double?).map { String(format: "%.0f", $0) } ?? "",
                formats,
                compilationByGame[id] ?? "",
                (r["origin"] as String?) ?? "",
                (r["last_played_at"] as Date?).map { csvDateFormatter.string(from: $0) } ?? "",
                // "Holds up today?" (v16) — appended last so existing column positions never move.
                (r["holds_up"] as String?) ?? "",
                // Batocera play time (v17) — after holds_up, same rule.
                (r["batocera_playtime_s"] as Int?).map { hours(fromSeconds: $0) } ?? "",
            ]
            lines.append(field.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func hours(fromSeconds seconds: Int) -> String {
        String(format: "%.1f", Double(seconds) / 3600)
    }

    /// RFC-4180 field quoting: wrap in quotes and double internal quotes when the
    /// field contains a comma, quote, or newline.
    static func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
