import Foundation

/// A streaming reader for one Batocera `gamelist.xml` (PLAN §15). Uses an event-based
/// `XMLParser` (SAX), never a DOM: a 4 MB gamelist is parsed one element at a time and
/// only the finished ``BatoceraGame`` values are kept, so memory stays proportional to
/// the result, not the file. Tolerant by construction:
///  - unknown tags (`bezel`, `map`, `cheevosId`, `arcadesystemname`, `multidisk`…) are
///    ignored;
///  - missing tags leave their field nil / 0 / false;
///  - `<folder>` nodes are skipped entirely (they are directory metadata, not games);
///  - XML entities (`&amp;`, `&lt;`) are decoded by `XMLParser`;
///  - `<hidden>` entries are dropped by default (PLAN §15 — the catalogue never shows them).
///
/// A malformed file throws ``BatoceraError/malformedGamelist``; the caller
/// (``BatoceraSync``) catches it per-system and continues.
struct BatoceraGamelistReader: Sendable {

    /// Whether hidden entries are dropped (default true, PLAN §15). Exposed so a test can
    /// keep them to assert the flag is parsed.
    var dropHidden: Bool

    init(dropHidden: Bool = true) { self.dropHidden = dropHidden }

    /// Parse a gamelist from an in-memory `Data` (tests, and small files). `system` is the
    /// Batocera folder name stamped onto every game.
    func read(system: String, data: Data) throws -> [BatoceraGame] {
        let delegate = ParseDelegate(system: system, dropHidden: dropHidden)
        let parser = XMLParser(data: data)
        return try run(parser, delegate: delegate, system: system)
    }

    /// Parse a gamelist by streaming a file from disk (the real path). Uses an
    /// `InputStream` so the file is never fully materialised as a string.
    func read(system: String, url: URL) throws -> [BatoceraGame] {
        guard let stream = InputStream(url: url) else {
            throw BatoceraError.unreadableFile(system: system, path: url.path)
        }
        let delegate = ParseDelegate(system: system, dropHidden: dropHidden)
        let parser = XMLParser(stream: stream)
        return try run(parser, delegate: delegate, system: system)
    }

    private func run(_ parser: XMLParser, delegate: ParseDelegate, system: String) throws -> [BatoceraGame] {
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            let detail = parser.parserError?.localizedDescription
                ?? "line \(parser.lineNumber)"
            throw BatoceraError.malformedGamelist(system: system, detail: detail)
        }
        return delegate.games
    }
}

/// The SAX delegate. Holds only the current element's text buffer and the fields of the
/// one game being assembled — everything else is already a finished value in `games`.
private final class ParseDelegate: NSObject, XMLParserDelegate {
    let system: String
    let dropHidden: Bool
    var games: [BatoceraGame] = []

    private var inGame = false
    private var inFolder = false
    private var currentTag = ""
    private var text = ""
    private var fields: [String: String] = [:]
    private var gameID: String?

    init(system: String, dropHidden: Bool) {
        self.system = system
        self.dropHidden = dropHidden
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "game":
            inGame = true
            fields.removeAll(keepingCapacity: true)
            gameID = attributeDict["id"]
        case "folder":
            inFolder = true            // consume and ignore its children
        default:
            break
        }
        currentTag = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Only accumulate while inside a leaf tag of a game.
        guard inGame, !inFolder else { return }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inGame, !inFolder else { return }
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "folder" { inFolder = false; return }
        if elementName == "game" {
            if inGame { finishGame() }
            inGame = false
            return
        }
        guard inGame, !inFolder else { return }
        // Record the leaf's trimmed text (last one wins on a duplicate tag).
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { fields[elementName] = value }
        text = ""
    }

    private func finishGame() {
        let hidden = boolFlag(fields["hidden"])
        if hidden && dropHidden { return }

        guard let path = fields["path"], !path.isEmpty else { return }   // no path ⇒ unusable
        let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? Self.baseName(of: path)

        let game = BatoceraGame(
            system: system,
            relativePath: path,
            name: name,
            screenScraperID: gameID,
            md5: fields["md5"],
            region: fields["region"]?.lowercased(),
            lang: fields["lang"]?.lowercased(),
            genre: fields["genre"],
            family: fields["family"],
            developer: fields["developer"],
            publisher: fields["publisher"],
            releaseYear: BatoceraDate.year(from: fields["releasedate"]),
            rating: fields["rating"].flatMap(Double.init),
            players: fields["players"],
            playCount: Int(fields["playcount"] ?? "") ?? 0,
            gameTimeSeconds: Int(fields["gametime"] ?? "") ?? 0,
            lastPlayed: BatoceraDate.date(from: fields["lastplayed"]),
            isFavorite: boolFlag(fields["favorite"]),
            isHidden: hidden,
            imageRelativePath: fields["image"],
            thumbnailRelativePath: fields["thumbnail"])
        games.append(game)
    }

    /// Batocera writes `true` for a set flag and either omits the tag or writes an empty
    /// string when unset.
    private func boolFlag(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return raw == "true" || raw == "1" || raw == "yes"
    }

    private static func baseName(of path: String) -> String {
        let last = path.split(whereSeparator: { $0 == "/" }).last.map(String.init) ?? path
        // Strip a trailing extension and parenthesised tags for a readable fallback name.
        var name = last
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            name = String(name[name.startIndex..<dot])
        }
        return LibretroFilenameParser.stripTags(name)
    }
}
