import Foundation

/// One `<game>` entry read from a Batocera `gamelist.xml` (PLAN §15) — a plain,
/// `Sendable` value with no I/O. Its `system` is the Batocera folder name (`snes`,
/// `megadrive`, `psx`…); the VGN platform slug is resolved separately by
/// ``BatoceraSystems``. `<folder>` nodes and unknown tags are ignored by the reader,
/// so every field here comes from a real game entry.
struct BatoceraGame: Sendable, Hashable, Identifiable {
    /// The Batocera system folder this entry belongs to (e.g. `snes`).
    var system: String
    /// The `<path>` value as written, relative to the system folder
    /// (`./Parodius (Europe).zip`). The stable identity is `(system, relativePath)`.
    var relativePath: String
    /// The clean `<name>` (`Eye of the Beholder`). Falls back to the file's base name
    /// (tags stripped) when the entry has no `<name>`.
    var name: String

    var screenScraperID: String?
    var md5: String?
    /// The `<region>` code as written, lowercased (`us`, `eu`, `jp`, `wr`…).
    var region: String?
    var lang: String?
    /// The raw ScreenScraper `<genre>` (`Shoot'em Up / Horizontal`).
    var genre: String?
    /// The `<family>` (series), present on ~30 % of entries.
    var family: String?
    var developer: String?
    var publisher: String?
    /// The four-digit year parsed from `<releasedate>` (`19940402T000000` → 1994).
    var releaseYear: Int?
    /// `<rating>` on ScreenScraper's 0…1 scale.
    var rating: Double?
    /// `<players>` as written (`1`, `1-2`, `4`…) — kept as text.
    var players: String?

    var playCount: Int
    /// `<gametime>` in seconds (total, sessions > 5 s). 0 when never played.
    var gameTimeSeconds: Int
    /// `<lastplayed>` parsed from `YYYYMMDDTHHMMSS`.
    var lastPlayed: Date?
    var isFavorite: Bool
    /// `<hidden>` — the reader drops these before they reach a caller (PLAN §15), but the
    /// flag is preserved on the value for tests / diagnostics.
    var isHidden: Bool

    var imageRelativePath: String?
    var thumbnailRelativePath: String?

    /// The file's base name (last path component of `relativePath`), used for libretro
    /// folding and normalisation (`./Parodius (Europe).zip` → `Parodius (Europe).zip`).
    var fileName: String {
        let trimmed = relativePath.hasPrefix("./") ? String(relativePath.dropFirst(2)) : relativePath
        return trimmed.split(whereSeparator: { $0 == "/" }).last.map(String.init) ?? trimmed
    }

    /// Stable identity within a catalogue: `<system>/<relativePath>` — also the importer
    /// `external_id` when a ROM is promoted (PLAN §15).
    var id: String { "\(system)/\(relativePath)" }

    init(system: String, relativePath: String, name: String,
         screenScraperID: String? = nil, md5: String? = nil, region: String? = nil,
         lang: String? = nil, genre: String? = nil, family: String? = nil,
         developer: String? = nil, publisher: String? = nil, releaseYear: Int? = nil,
         rating: Double? = nil, players: String? = nil, playCount: Int = 0,
         gameTimeSeconds: Int = 0, lastPlayed: Date? = nil, isFavorite: Bool = false,
         isHidden: Bool = false, imageRelativePath: String? = nil,
         thumbnailRelativePath: String? = nil) {
        self.system = system
        self.relativePath = relativePath
        self.name = name
        self.screenScraperID = screenScraperID
        self.md5 = md5
        self.region = region
        self.lang = lang
        self.genre = genre
        self.family = family
        self.developer = developer
        self.publisher = publisher
        self.releaseYear = releaseYear
        self.rating = rating
        self.players = players
        self.playCount = playCount
        self.gameTimeSeconds = gameTimeSeconds
        self.lastPlayed = lastPlayed
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.imageRelativePath = imageRelativePath
        self.thumbnailRelativePath = thumbnailRelativePath
    }
}

/// Parsing of the two Batocera date shapes, shared by the reader (PLAN §15):
/// `<releasedate>` = `YYYYMMDDT000000`, `<lastplayed>` = `YYYYMMDDTHHMMSS`. Both are
/// stored without a zone; Batocera writes them in local time, so we read them in the
/// current calendar (the exact instant is not load-bearing — only the date is shown).
enum BatoceraDate {
    /// The four-digit year of a `<releasedate>` / `<lastplayed>` value, or nil.
    static func year(from raw: String?) -> Int? {
        guard let raw, raw.count >= 4 else { return nil }
        let y = Int(raw.prefix(4))
        // Guard against `00000000T…` sentinels ScreenScraper occasionally writes.
        return (y ?? 0) > 1900 ? y : nil
    }

    /// A full `YYYYMMDDTHHMMSS` value as a `Date`, or nil when unparseable / a sentinel.
    static func date(from raw: String?) -> Date? {
        guard let raw, let tIndex = raw.firstIndex(of: "T") ?? raw.firstIndex(of: "t") else {
            // A bare date (`YYYYMMDD`) is still usable.
            return dateOnly(from: raw)
        }
        let datePart = String(raw[raw.startIndex..<tIndex])
        let timePart = String(raw[raw.index(after: tIndex)...])
        guard datePart.count == 8,
              let y = Int(datePart.prefix(4)), y > 1900,
              let mo = Int(datePart.dropFirst(4).prefix(2)), (1...12).contains(mo),
              let d = Int(datePart.dropFirst(6).prefix(2)), (1...31).contains(d) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        if timePart.count >= 6 {
            comps.hour = Int(timePart.prefix(2))
            comps.minute = Int(timePart.dropFirst(2).prefix(2))
            comps.second = Int(timePart.dropFirst(4).prefix(2))
        }
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    private static func dateOnly(from raw: String?) -> Date? {
        guard let raw, raw.count == 8, let y = Int(raw.prefix(4)), y > 1900,
              let mo = Int(raw.dropFirst(4).prefix(2)), let d = Int(raw.dropFirst(6).prefix(2)) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
