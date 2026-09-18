import Foundation

/// Title normalisation as an explicit *ladder* of progressively looser normal
/// forms. Callers choose how aggressive to be; nothing strips a title further
/// than the level asked for.
///
/// **Levels**
/// - `.fold` — case/diacritics/™®© folding, unicode dash & quote normalisation,
///   whitespace collapse. Punctuation preserved. (Display-ish.)
/// - `.canonical` — `.fold` + `&`↔`and`, roman↔arabic numerals, punctuation → space.
///   The main comparison form. Keeps articles, subtitles, editions, and
///   remaster/HD/remake/Part words.
/// - `.articleless` — `.canonical` + strip leading articles (incl. French and the
///   No-Intro "Title, The" comma form) + strip trailing edition/budget tags.
///   Keeps subtitles and remaster/HD/remake words. **Recommended default for
///   fuzzy matching.**
/// - `.core` — `.articleless` + drop the subtitle (keep the main title only).
///   Loosest; use deliberately.
///
/// **Deliberately NOT stripped at any level:** "Remastered", "HD", "Remake",
/// "Part I/II", "Trilogy" — in VGN these denote *separate games* (PLAN §4), so
/// folding them together would be wrong.
enum TitleNormalizer {

    enum Level: Int, CaseIterable, Sendable, Comparable {
        case fold = 0
        case canonical = 1
        case articleless = 2
        case core = 3
        static func < (l: Level, r: Level) -> Bool { l.rawValue < r.rawValue }
    }

    /// Leading articles to strip (English + French), as normalized tokens.
    static let leadingArticles: Set<String> = [
        "the", "a", "an", "le", "la", "les", "l", "un", "une", "des",
    ]

    /// Trailing edition / budget-range tags, longest phrases first so the longest
    /// trailing match wins.
    static let editionPhrases: [[String]] = {
        let raw = [
            "game of the year edition", "game of the year",
            "goty edition", "goty",
            "complete edition", "definitive edition", "deluxe edition",
            "collectors edition", "collector s edition", "gold edition",
            "special edition", "anniversary edition", "ultimate edition",
            "directors cut", "director s cut",
            "greatest hits", "players choice", "player s choice",
            "platinum", "essentials", "complete", "definitive", "deluxe",
            "collectors",
        ]
        return raw.map { $0.split(separator: " ").map(String.init) }
            .sorted { $0.count > $1.count }
    }()

    // MARK: - Public

    /// Normalise `raw` to the given `level`.
    static func normalize(_ raw: String, level: Level) -> String {
        var s = foldBasics(raw)

        if level >= .core {
            s = mainTitle(s)
        }
        if level >= .articleless {
            s = removeCommaArticle(s)
        }
        if level >= .canonical {
            s = canonicalize(s)
        } else {
            return collapse(s)
        }
        if level >= .articleless {
            s = stripLeadingArticle(s)
            s = stripEditionTags(s)
        }
        return collapse(s)
    }

    /// Tokens of the normalised title at `level`.
    static func tokens(_ raw: String, level: Level) -> [String] {
        normalize(raw, level: level).split(separator: " ").map(String.init)
    }

    // MARK: - Stages

    /// Lowercase, fold diacritics, strip ™®©, normalise fancy dashes/quotes.
    static func foldBasics(_ raw: String) -> String {
        var s = raw
        // Drop parenthesised / bracketed tag groups: "(Europe)", "(En,Fr,De)",
        // "(Disc 1)", "[!]" — these are never part of the real title (No-Intro /
        // Redump / budget-label conventions) and would otherwise leak into the
        // comparison. Applied first, before any other folding.
        s = s.replacingOccurrences(of: #"\s*\([^()]*\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\[[^\[\]]*\]"#, with: "", options: .regularExpression)
        for symbol in ["™", "®", "©", "℠"] { s = s.replacingOccurrences(of: symbol, with: "") }
        // Normalise unicode dashes and quotes to ASCII so later stages see one form.
        let dashes = ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}"]
        for d in dashes { s = s.replacingOccurrences(of: d, with: "-") }
        let quotes = ["\u{2018}", "\u{2019}", "\u{02BC}", "\u{2032}"]
        for q in quotes { s = s.replacingOccurrences(of: q, with: "'") }
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        // Diacritic-insensitive fold (Pokémon → pokemon, Ōkami → okami), lowercased.
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return collapse(s)
    }

    /// Keep only the main title, dropping the first subtitle at `:`, ` - `, ` – `.
    static func mainTitle(_ s: String) -> String {
        // Find the earliest separator.
        var cut: String.Index? = nil
        if let r = s.range(of: ":") { cut = r.lowerBound }
        for sep in [" - ", " – ", " — "] {
            if let r = s.range(of: sep), cut == nil || r.lowerBound < cut! {
                cut = r.lowerBound
            }
        }
        if let cut { return collapse(String(s[..<cut])) }
        return s
    }

    /// Remove the trailing-article comma form: "Legend of Zelda, The" → "Legend of
    /// Zelda". Runs before punctuation removal so the comma is still present.
    static func removeCommaArticle(_ s: String) -> String {
        let articles = "the|an|a|les|le|la|l'|une|un|des"
        let pattern = ",\\s+(?:\(articles))(?=\\s|$|:|\\-)"
        return s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression])
    }

    /// `&`→`and`, roman→arabic numerals, punctuation → space, collapse.
    static func canonicalize(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&", with: " and ")
        // Replace every non-alphanumeric scalar with a space.
        var scalars = String.UnicodeScalarView()
        for u in t.unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                scalars.append(u)
            } else {
                scalars.append(" ")
            }
        }
        t = String(scalars)
        let converted = t.split(separator: " ").map { romanToArabic(String($0)) }
        return converted.joined(separator: " ")
    }

    /// Strip a single leading article token.
    static func stripLeadingArticle(_ s: String) -> String {
        var tokens = s.split(separator: " ").map(String.init)
        if let first = tokens.first, leadingArticles.contains(first), tokens.count > 1 {
            tokens.removeFirst()
        }
        return tokens.joined(separator: " ")
    }

    /// Strip trailing edition/budget tags (never reducing the title to empty).
    static func stripEditionTags(_ s: String) -> String {
        var tokens = s.split(separator: " ").map(String.init)
        var changed = true
        while changed {
            changed = false
            for phrase in editionPhrases where tokens.count > phrase.count {
                if Array(tokens.suffix(phrase.count)) == phrase {
                    tokens.removeLast(phrase.count)
                    changed = true
                    break
                }
            }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Numerals

    /// Convert a token to its arabic value when it is a canonical multi-character
    /// roman numeral (II…), leaving single-character tokens (I, V, X, L, C, D, M)
    /// untouched — "X" in "Mega Man X" / "Final Fantasy X" must stay "x".
    static func romanToArabic(_ token: String) -> String {
        guard token.count >= 2 else { return token }
        guard token.allSatisfy({ "ivxlcdm".contains($0) }) else { return token }
        guard let value = romanValue(token), value >= 1, value <= 3999 else { return token }
        // Only accept canonical spellings (round-trips), rejecting "iiii", "vv"…
        guard arabicToRoman(value) == token else { return token }
        return String(value)
    }

    private static func romanValue(_ s: String) -> Int? {
        let map: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100, "d": 500, "m": 1000]
        var total = 0
        var prev = 0
        for ch in s.reversed() {
            guard let v = map[ch] else { return nil }
            if v < prev { total -= v } else { total += v; prev = v }
        }
        return total
    }

    private static func arabicToRoman(_ n: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var n = n
        var out = ""
        for (value, sym) in table {
            while n >= value { out += sym; n -= value }
        }
        return out
    }

    // MARK: - Helpers

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }
}
