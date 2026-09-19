import Foundation
@testable import VGN

/// Shared helpers for the Batocera suite: build synthetic `gamelist.xml` strings (entities,
/// folders, missing tags, multi-disc, regional twins, hidden, favourites, play-data edges)
/// and a seeded in-memory database with the real platform catalogue (so every Batocera slug
/// resolves). **No test in this suite ever reads `/Volumes/…`** — every gamelist here is
/// built in code.
enum BatoceraTestSupport {

    /// A migrated in-memory DB with the bundled platform catalogue seeded.
    static func makeSeededDB() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatforms(from: PlatformCatalog.entriesFromBundle())
        return db
    }

    /// One `<game>` spec for the XML builder. Only `path` is required.
    struct GameSpec {
        var id: String?
        var path: String
        var name: String?
        var genre: String?
        var family: String?
        var developer: String?
        var publisher: String?
        var region: String?
        var lang: String?
        var rating: String?
        var releasedate: String?
        var players: String?
        var md5: String?
        var playcount: String?
        var gametime: String?
        var lastplayed: String?
        var favorite: String?
        var hidden: String?
        var image: String?
        var thumbnail: String?
        /// Extra unknown tags to prove tolerance (e.g. `["bezel": "./x.png"]`).
        var extra: [String: String] = [:]

        init(path: String, name: String? = nil, id: String? = nil, genre: String? = nil,
             family: String? = nil, developer: String? = nil, publisher: String? = nil,
             region: String? = nil, lang: String? = nil, rating: String? = nil,
             releasedate: String? = nil, players: String? = nil, md5: String? = nil,
             playcount: String? = nil, gametime: String? = nil, lastplayed: String? = nil,
             favorite: String? = nil, hidden: String? = nil, image: String? = nil,
             thumbnail: String? = nil, extra: [String: String] = [:]) {
            self.id = id; self.path = path; self.name = name; self.genre = genre
            self.family = family; self.developer = developer; self.publisher = publisher
            self.region = region; self.lang = lang; self.rating = rating
            self.releasedate = releasedate; self.players = players; self.md5 = md5
            self.playcount = playcount; self.gametime = gametime; self.lastplayed = lastplayed
            self.favorite = favorite; self.hidden = hidden; self.image = image
            self.thumbnail = thumbnail; self.extra = extra
        }
    }

    /// Render a `gamelist.xml` string. `rawFolders` are extra literal `<folder>…</folder>`
    /// blocks injected to prove the reader skips them.
    static func gamelistXML(_ specs: [GameSpec], rawFolders: [String] = []) -> String {
        var xml = "<?xml version=\"1.0\"?>\n<gameList>\n"
        for folder in rawFolders { xml += folder + "\n" }
        for spec in specs {
            let idAttr = spec.id.map { " id=\"\(escape($0))\"" } ?? ""
            xml += "  <game\(idAttr)>\n"
            func tag(_ name: String, _ value: String?) {
                guard let value else { return }
                xml += "    <\(name)>\(escape(value))</\(name)>\n"
            }
            tag("path", spec.path)
            tag("name", spec.name)
            tag("desc", nil)
            tag("genre", spec.genre)
            tag("family", spec.family)
            tag("developer", spec.developer)
            tag("publisher", spec.publisher)
            tag("region", spec.region)
            tag("lang", spec.lang)
            tag("rating", spec.rating)
            tag("releasedate", spec.releasedate)
            tag("players", spec.players)
            tag("md5", spec.md5)
            tag("playcount", spec.playcount)
            tag("gametime", spec.gametime)
            tag("lastplayed", spec.lastplayed)
            tag("favorite", spec.favorite)
            tag("hidden", spec.hidden)
            tag("image", spec.image)
            tag("thumbnail", spec.thumbnail)
            for (k, v) in spec.extra.sorted(by: { $0.key < $1.key }) { tag(k, v) }
            xml += "  </game>\n"
        }
        xml += "</gameList>\n"
        return xml
    }

    static func data(_ specs: [GameSpec], rawFolders: [String] = []) -> Data {
        Data(gamelistXML(specs, rawFolders: rawFolders).utf8)
    }

    /// Write a synthetic share tree under a fresh temp folder: `<root>/roms/<system>/gamelist.xml`.
    /// Returns the share root. Caller removes the folder.
    static func makeShareTree(_ systems: [String: [GameSpec]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatoceraShare-\(UUID().uuidString)", isDirectory: true)
        let roms = root.appendingPathComponent("roms", isDirectory: true)
        for (system, specs) in systems {
            let dir = roms.appendingPathComponent(system, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try gamelistXML(specs).write(to: dir.appendingPathComponent("gamelist.xml"),
                                         atomically: true, encoding: .utf8)
        }
        return root
    }

    static func removeTree(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
