import Foundation

/// A parsed libretro-thumbnails / No-Intro / Redump style filename, e.g.
/// `Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De) (Rev 1).png`.
///
/// libretro thumbnail filenames additionally substitute the characters
/// `& * / : ` < > ? \ | "` with `_`; that substitution is reversed for lookup by
/// the matching key (see `LibretroIndex`), not here — this type reflects the
/// filename as written.
struct LibretroFilename: Equatable, Sendable {
    /// The title with the trailing-article comma form kept as written
    /// ("Legend of Zelda, The"). `titleLeading` gives the reflowed form.
    var title: String
    var regions: [String]
    var languages: [String]
    var disc: Int?
    var revision: String?
    /// Remaining parenthesised tags not otherwise classified.
    var otherTags: [String]
    /// Beta/Proto/Demo/Sample/Prototype etc. — de-prioritised in matching.
    var isPrerelease: Bool

    /// Title reflowed to leading-article form ("The Legend of Zelda").
    var titleLeading: String {
        Self.reflowArticle(title)
    }

    static func reflowArticle(_ t: String) -> String {
        // "Main, Article" or "Main, Article - Subtitle" → "Article Main - Subtitle".
        // The comma-article sits at the boundary between the main title and any
        // subtitle, so we move only the article to the front and keep the rest
        // (including a " - Subtitle") in place.
        let articles = ["The", "An", "A", "Les", "Le", "La", "L'", "Une", "Un", "Des"]
        for art in articles {
            guard let r = t.range(of: ", \(art)") else { continue }
            let afterIndex = r.upperBound
            // Must be a whole word: end of string, or followed by space / ':'.
            if afterIndex == t.endIndex || t[afterIndex] == " " || t[afterIndex] == ":" || art.hasSuffix("'") {
                let head = String(t[..<r.lowerBound])
                let rest = String(t[afterIndex...])
                return collapse("\(art) \(head)\(rest)")
            }
        }
        return t
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}

enum LibretroFilenameParser {

    /// Known region names (subset of the No-Intro region vocabulary that occurs in
    /// libretro thumbnail repos).
    static let regions: Set<String> = [
        "Europe", "USA", "Japan", "World", "France", "Germany", "Spain", "Italy",
        "Netherlands", "Sweden", "Australia", "Canada", "Korea", "China", "Taiwan",
        "Hong Kong", "Brazil", "Asia", "UK", "Russia", "Scandinavia", "Unknown",
        "Latin America", "Portugal", "Belgium", "Finland", "Denmark", "Norway",
        "Poland", "Greece",
    ]

    static func parse(_ filename: String) -> LibretroFilename {
        // Drop a trailing image extension.
        var name = filename
        for ext in [".png", ".jpg", ".jpeg"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }

        let segments = parenSegments(name)
        var regionsOut: [String] = []
        var languagesOut: [String] = []
        var disc: Int? = nil
        var revision: String? = nil
        var other: [String] = []
        var prerelease = false

        for (i, seg) in segments.enumerated() {
            let trimmed = seg.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            if i == 0 && parts.allSatisfy({ regions.contains($0) }) {
                regionsOut = parts
                continue
            }
            if !parts.isEmpty && parts.allSatisfy({ isLanguageCode($0) }) {
                languagesOut = parts
                continue
            }
            if let d = discNumber(trimmed) { disc = d; continue }
            if let r = revisionValue(trimmed) { revision = r; continue }
            let lower = trimmed.lowercased()
            if ["beta", "proto", "prototype", "demo", "sample", "alpha"].contains(where: { lower.contains($0) }) {
                prerelease = true
            }
            other.append(trimmed)
        }

        let title = stripTags(name)
        return LibretroFilename(
            title: title,
            regions: regionsOut,
            languages: languagesOut,
            disc: disc,
            revision: revision,
            otherTags: other,
            isPrerelease: prerelease
        )
    }

    // MARK: - Pieces

    static func parenSegments(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var buf = ""
        for ch in s {
            if ch == "(" {
                if depth == 0 { buf.removeAll(keepingCapacity: true) } else { buf.append(ch) }
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 { out.append(buf) } else if depth > 0 { buf.append(ch) }
            } else if depth > 0 {
                buf.append(ch)
            }
        }
        return out
    }

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*\([^()]*\)"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\[[^\[\]]*\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func isLanguageCode(_ s: String) -> Bool {
        // En, Fr, Ja, En-US, Zh-Hans …
        s.range(of: #"^[A-Z][a-z](?:-(?:[A-Z]{2}|[A-Z][a-z]+))?$"#, options: .regularExpression) != nil
    }

    static func discNumber(_ s: String) -> Int? {
        guard let r = s.range(of: #"^Dis[ck]\s+(\d+)"#, options: .regularExpression) else { return nil }
        return Int(s[r].split(separator: " ").last ?? "")
    }

    static func revisionValue(_ s: String) -> String? {
        guard s.range(of: #"^Rev[\s\-]"#, options: .regularExpression) != nil else { return nil }
        let parts = s.split(whereSeparator: { $0 == " " || $0 == "-" })
        return parts.count >= 2 ? String(parts[1]) : nil
    }
}
