import Foundation

/// A pure, tested **query ladder** for the HowLongToBeat fallback (PLAN §5.3, D3):
/// long / edition-laden library titles (which come straight from IGDB, so a game may be
/// stored as "Batman: Arkham Knight - Season of Infamy: Most Wanted Expansion" or
/// "NieR: Automata – Game of the YoRHa Edition") rarely match HLTB verbatim. Rather than
/// spend requests blindly, the caller tries a short, ordered list of progressively
/// looser queries and **stops at the first confident match**.
///
/// Foundation-only, so every family + counter-case is unit-tested. It never invents a
/// query: each step only *removes* packaging noise, and a step that changes nothing is
/// dropped (deduped case-insensitively). At most ``maxQueries`` queries per game per run.
///
/// The ladder (in order):
///  1. **the title as is** — the common case; HLTB often has the exact IGDB name.
///  2. **noise stripped, subtitle kept** — trademark symbols, a trailing platform tail
///     (`PlatformTail`), and trailing edition / packaging tags ("Complete Edition",
///     "GOTY", "Definitive Edition", "Director's Cut", a conservative "Remastered"/"HD"…).
///     The subtitle after a colon is **kept** here.
///  3. **also drop the subtitle** — last resort: cut at the first `:`/` - ` separator,
///     then re-strip edition tags. Reached only when 1 & 2 found nothing confident.
///
/// Wave 21 (D2b): when the subtitle is a **series tag** ("The Beast Within: *A Gabriel
/// Knight Mystery*"), rung 2 is the **subtitle-swapped** query instead ("Gabriel Knight
/// Beast Within", ``subtitleSwapped(_:)``) — still ≤ 3 queries, the full title still first.
///
/// Deliberately conservative: it never strips a **numeral** ("Doom 3", "Resident Evil 2"
/// keep their number, and neither collapses to a shorter game), and a bare qualifier that
/// is not followed by "Edition"/"Cut" is left alone ("Persona 5 Royal" keeps *Royal*).
enum HLTBQueryLadder {
    /// At most this many queries per game per run (PLAN §5.3, D3).
    static let maxQueries = 3

    /// The ordered, de-duplicated queries to try. Always begins with the raw title; the
    /// caller searches each in order and stops at the first confident match.
    static func queries(for rawTitle: String) -> [String] {
        var out: [String] = []
        func add(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, out.count < maxQueries else { return }
            if !out.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                out.append(trimmed)
            }
        }
        let original = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        add(original)                                   // 1 — as is
        if let swapped = subtitleSwapped(original) {
            add(swapped)                                // 2' — series tag → "Series Main" (wave 21)
        } else {
            add(cleaned(original, dropSubtitle: false)) // 2 — noise off, subtitle kept
        }
        add(cleaned(original, dropSubtitle: true))      // 3 — also drop the subtitle
        return out
    }

    /// The **subtitle-swapped** query for a title whose subtitle is a series tag (wave 21
    /// D2b): "The Beast Within: A Gabriel Knight Mystery" → "Gabriel Knight Beast Within" —
    /// the series name first, then the main title without its leading article, which is how
    /// HowLongToBeat (and most catalogues) name such games ("Gabriel Knight II: The Beast
    /// Within"). Nil when the subtitle is not a series tag (``TitleTokenSet/seriesTag(in:)``),
    /// so ordinary subtitles ("NieR: Automata", "Batman: Arkham Knight – Season of Infamy")
    /// keep the old ladder. Rung 1 (the full title) is always tried first.
    static func subtitleSwapped(_ rawTitle: String) -> String? {
        guard let tag = TitleTokenSet.seriesTag(in: cleaned(rawTitle, dropSubtitle: false)) else { return nil }
        var mainWords = collapse(tag.main).split(separator: " ").map(String.init)
        if let first = mainWords.first, ["the", "a", "an"].contains(first.lowercased()), mainWords.count > 1 {
            mainWords.removeFirst()
        }
        return collapse(tag.series + " " + mainWords.joined(separator: " "))
    }

    /// The search text prefilled into the manual "Find on HowLongToBeat…" sheet (D5):
    /// the second rung — noise stripped, subtitle kept — so the owner starts from a clean,
    /// editable query rather than the raw IGDB mouthful.
    static func prefill(for rawTitle: String) -> String {
        let cleanedTitle = cleaned(rawTitle, dropSubtitle: false)
        return cleanedTitle.isEmpty ? rawTitle.trimmingCharacters(in: .whitespacesAndNewlines) : cleanedTitle
    }

    // MARK: - Cleaning

    /// Strip packaging noise from a title: trademark symbols, a trailing platform tail,
    /// and trailing edition tags — optionally dropping the subtitle first.
    static func cleaned(_ title: String, dropSubtitle: Bool) -> String {
        var s = title
        for symbol in ["™", "®", "©", "℠"] { s = s.replacingOccurrences(of: symbol, with: "") }
        s = PlatformTail.drop(s)
        s = stripEditionTails(s)
        if dropSubtitle {
            s = droppedSubtitle(s)
            s = stripEditionTails(s)
        }
        return collapse(s)
    }

    /// Cut everything from the first subtitle separator (`:`, ` - `, ` – `, ` — `). Never
    /// returns empty — a title that *is* only a subtitle marker is left untouched.
    static func droppedSubtitle(_ s: String) -> String {
        var cut: String.Index?
        if let r = s.range(of: ":") { cut = r.lowerBound }
        for sep in [" - ", " – ", " — "] {
            if let r = s.range(of: sep), cut == nil || r.lowerBound < cut! { cut = r.lowerBound }
        }
        guard let cut else { return s }
        let head = collapse(String(s[..<cut]))
        return head.isEmpty ? s : head
    }

    /// Trailing edition / packaging tags to remove, longest / most-specific first. Each is
    /// a *whole trailing phrase*, optionally preceded by a `-`/`–`/`:` separator, matched
    /// case-insensitively and looped until stable. A `.+` in a pattern is bounded to a
    /// single run of the tail (no separator inside it), so "Game of the YoRHa Edition"
    /// comes off "NieR: Automata – Game of the YoRHa Edition" while the subtitle stays.
    static let editionTailPatterns: [String] = [
        #"game of the year edition"#,
        #"game of the [^-–—:]+ edition"#,   // GOTY parodies: "Game of the YoRHa Edition"
        #"goty edition"#, #"goty"#,
        #"complete edition"#, #"definitive edition"#, #"deluxe edition"#,
        #"gold edition"#, #"ultimate edition"#, #"special edition"#,
        #"collector'?s edition"#, #"limited edition"#, #"anniversary edition"#,
        #"enhanced edition"#, #"legendary edition"#, #"royal edition"#,
        #"director'?s cut"#,
        #"remastered"#, #"remaster"#, #"hd"#,
    ]

    static func stripEditionTails(_ input: String) -> String {
        var s = collapse(input)
        var changed = true
        while changed {
            changed = false
            for phrase in editionTailPatterns {
                // Optional separator run + the phrase, at the very end. Require at least one
                // word to survive (never reduce a title to nothing).
                let pattern = #"(?i)\s*[-–—:]?\s+"# + phrase + #"\s*$"#
                guard let range = s.range(of: pattern, options: .regularExpression) else { continue }
                let stripped = collapse(String(s[..<range.lowerBound]))
                guard !stripped.isEmpty else { continue }
                s = stripped
                changed = true
                break
            }
        }
        return s
    }

    // MARK: - Helpers

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
    }
}
