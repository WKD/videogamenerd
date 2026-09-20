import Foundation

/// Cleans a library title into a sensible IGDB search query to *prefill* the link
/// sheet (PLAN §5.1). The owner edits it freely — this only strips the noise that
/// keeps a weird edition / localised title from matching (®/™, edition phrases FR/EN,
/// region + platform tails, a trailing " - US"). It never lowercases or folds, so the
/// field stays readable; the actual search folds via IGDB. Pure Foundation.
enum IGDBLinkQuery {

    /// Trailing "region / platform" words that a shelf export often appends
    /// (e.g. "Evolution Worlds - GameCube - US"). Compared case-insensitively.
    private static let regionTails: Set<String> = [
        "us", "usa", "eu", "eur", "europe", "pal", "ntsc", "ntsc-u", "ntsc-j",
        "jp", "jpn", "japan", "uk", "fr", "fra", "france", "de", "ger", "germany",
        "na", "world", "int", "intl", "region free", "region-free",
    ]

    /// Platform names/abbreviations sometimes appended as a tail segment.
    private static let platformTails: Set<String> = [
        "gamecube", "gc", "wii", "wii u", "wiiu", "switch", "nintendo switch",
        "ps1", "psx", "ps2", "ps3", "ps4", "ps5", "psp", "ps vita", "vita",
        "playstation", "playstation 2", "playstation 3", "playstation 4",
        "xbox", "xbox 360", "xbox one", "pc", "mac", "dreamcast", "saturn",
        "snes", "nes", "n64", "gba", "ds", "3ds", "game boy", "megadrive", "genesis",
    ]

    /// Trailing edition phrases (English + French) to strip. Multi-word phrases first.
    private static let editionPhrases: [[String]] = [
        ["game", "of", "the", "year", "edition"],
        ["goty", "edition"],
        ["complete", "edition"],
        ["definitive", "edition"],
        ["collector's", "edition"], ["collectors", "edition"], ["collector", "edition"],
        ["limited", "edition"], ["edition", "limitée"], ["édition", "limitée"],
        ["deluxe", "edition"], ["édition", "deluxe"],
        ["special", "edition"], ["édition", "spéciale"], ["edition", "spéciale"],
        ["anniversary", "edition"],
        ["remastered"], ["remaster"], ["hd", "remaster"],
        ["directors", "cut"], ["director's", "cut"],
        ["game", "of", "the", "year"],
        ["goty"], ["hd"], ["deluxe"],
        ["édition", "jeu", "de", "l'année"],
    ]

    /// Produce the prefilled query for a game title.
    static func clean(_ raw: String) -> String {
        // 1. Drop trademark/symbol marks and parenthesised / bracketed tag groups.
        var s = raw
        for symbol in ["™", "®", "©", "℠"] { s = s.replacingOccurrences(of: symbol, with: "") }
        s = s.replacingOccurrences(of: #"\s*\([^()]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[[^\[\]]*\]"#, with: "", options: .regularExpression)

        // 2. Peel trailing " - <region/platform>" segments (repeatedly).
        s = stripTrailingTailSegments(s)

        // 2b. Drop a bare PlayStation platform tail Sony appends to a PSN twin ("… PS4 & PS5",
        // "… (PS4)") — shared with the PSN importer via `PlatformTail` (PLAN §5.1 / §13.3). The
        // displayed "Current: …" line keeps the real title; only this prefill is cleaned.
        s = PlatformTail.drop(s)

        // 3. Drop trailing edition phrases (never emptying the title).
        s = stripEditionPhrases(s)

        return collapse(s)
    }

    /// Repeatedly remove a trailing " - X" (or " – X") segment when X is a region or
    /// platform tail, e.g. "Evolution Worlds - GameCube - US" → "Evolution Worlds".
    private static func stripTrailingTailSegments(_ s: String) -> String {
        var current = s
        while true {
            guard let range = lastDashSegment(current) else { break }
            let tail = current[range.tailStart...].trimmingCharacters(in: .whitespaces).lowercased()
            guard regionTails.contains(tail) || platformTails.contains(tail) else { break }
            current = String(current[..<range.dashStart]).trimmingCharacters(in: .whitespaces)
        }
        return current
    }

    /// The last " - " / " – " / " — " separator in `s`, as the index just before it and
    /// the index just after it; nil when there is none.
    private static func lastDashSegment(_ s: String) -> (dashStart: String.Index, tailStart: String.Index)? {
        var best: (Range<String.Index>)?
        for sep in [" - ", " – ", " — "] {
            if let r = s.range(of: sep, options: .backwards) {
                if best == nil || r.lowerBound > best!.lowerBound { best = r }
            }
        }
        guard let r = best else { return nil }
        return (r.lowerBound, r.upperBound)
    }

    private static func stripEditionPhrases(_ s: String) -> String {
        var tokens = s.split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            for phrase in editionPhrases where tokens.count > phrase.count {
                let suffix = tokens.suffix(phrase.count).map { $0.lowercased() }
                if suffix == phrase {
                    tokens.removeLast(phrase.count)
                    changed = true
                    break
                }
            }
        }
        return tokens.joined(separator: " ")
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
