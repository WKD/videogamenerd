import Foundation

/// An **order-free** title similarity (PLAN §5.3, wave 21 D2) — the second opinion the HLTB
/// matcher takes next to ``FuzzyMatch``. Fuzzy edit-distance scoring reads a title left to
/// right, so the same words in another order / segmentation score low:
/// "The Beast Within: A Gabriel Knight Mystery" (IGDB) vs "Gabriel Knight II: The Beast
/// Within" (HowLongToBeat) fell under the plausible threshold and the game came back
/// "not found". This scorer compares **sets of significant words** instead.
///
/// Foundation-only and pure, so the formula and every counter-case are unit-tested.
///
/// **Significant tokens** `S(t)`: ``TitleNormalizer`` at `.articleless` (fold, lowercase,
/// diacritics, `&`→and, **roman → arabic numerals**, punctuation → space, leading article
/// and trailing edition tags off), minus the stopwords ``stopwords`` (a / an / the / of /
/// and); when the title's subtitle is a **series tag** ("A Gabriel Knight Mystery", see
/// ``seriesTag(in:)``) its article + genre word are dropped too, leaving the series name.
///
/// **Score** for `A = S(a)`, `B = S(b)` (either empty → 0):
///  - `A == B` (same words, any order) → ``sameSetScore`` (0.95);
///  - one side ⊂ the other ("small" ⊂ "large") **and** the order-free bonus is allowed →
///    `0.90 + 0.05 · |small| / |large|` (≥ 0.9375, i.e. confident on text alone);
///  - otherwise the **Dice** coefficient `2·|A∩B| / (|A|+|B|)`.
///
/// The bonus is allowed only when the subset is strong evidence of *the same game*:
///  - `|small| ≥ 3` and coverage `|small| / |large| ≥ 0.75` — short titles are prefixes of
///    their sequels/spin-offs ("Tomb Raider" ⊂ "Rise of the Tomb Raider");
///  - no extra word is a **numeral** ("Resident Evil" ⊂ "Resident Evil 2", "Doom" ⊂ "Doom 3"),
///    *unless* the smaller title carried a series tag — the "A <Series> Mystery" form
///    conventionally omits the series number, which is exactly the Gabriel Knight case;
///  - no extra word is a **separate-game word** (``separateGameWords`` — "Remake",
///    "Remastered", "HD", "Origins"…; PLAN §4 treats those as different games).
enum TitleTokenSet {

    /// Score when both titles have exactly the same significant words (any order).
    static let sameSetScore = 0.95
    /// Base of the order-free subset bonus; `+ 0.05 × coverage` on top.
    static let subsetBase = 0.90
    static let subsetCoverageWeight = 0.05
    /// Minimum size of the smaller token set for the subset bonus.
    static let subsetMinTokens = 3
    /// Minimum `|small| / |large|` for the subset bonus.
    static let subsetMinCoverage = 0.75

    /// Words that carry no identity ("of", "the"…).
    static let stopwords: Set<String> = ["a", "an", "the", "of", "and"]

    /// Extra words that make a *different* game (or a different package) — never covered
    /// by the order-free bonus (PLAN §4: Remastered / HD / Remake are separate games).
    static let separateGameWords: Set<String> = [
        "remake", "remastered", "remaster", "hd", "reloaded", "redux", "dx", "3d", "vr",
        "origins", "returns", "reborn", "rebirth", "zero", "trilogy", "collection",
        "anthology", "part", "episode", "chapter", "dlc", "expansion", "pack", "edition",
        "online", "legends", "revelations", "remix", "plus", "ultimate", "arcade", "portable",
    ]

    /// Genre words that close a series-tag subtitle ("A Gabriel Knight **Mystery**").
    static let seriesTagGenres: Set<String> = [
        "mystery", "adventure", "story", "tale", "saga", "novel", "thriller", "game",
    ]

    // MARK: - Series tag

    /// The pieces of a title whose subtitle is a **series tag** — `"<Main>: A <Series>
    /// <Genre>"` / `"<Main> - An <Series> <Genre>"` with 1–4 series words, e.g.
    /// "The Beast Within: A Gabriel Knight Mystery" → main "The Beast Within", series
    /// "Gabriel Knight". Nil for every other title (a normal subtitle is not a tag).
    struct SeriesTag: Sendable, Equatable {
        var main: String
        var series: String
    }

    static func seriesTag(in rawTitle: String) -> SeriesTag? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var cut: Range<String.Index>?
        for sep in [":", " - ", " – ", " — "] {
            if let r = title.range(of: sep), cut == nil || r.lowerBound < cut!.lowerBound { cut = r }
        }
        guard let cut else { return nil }
        let main = title[..<cut.lowerBound].trimmingCharacters(in: .whitespaces)
        let subtitle = title[cut.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !main.isEmpty else { return nil }
        let words = subtitle.split(separator: " ").map(String.init)
        guard words.count >= 3, words.count <= 6,
              ["a", "an"].contains(words[0].lowercased()),
              seriesTagGenres.contains(words[words.count - 1].lowercased()) else { return nil }
        let series = words[1..<(words.count - 1)].joined(separator: " ")
        guard !series.isEmpty else { return nil }
        return SeriesTag(main: main, series: series)
    }

    // MARK: - Tokens

    /// The significant tokens of a title (see the type doc) and whether it had a series tag.
    static func significantTokens(_ raw: String) -> (tokens: Set<String>, hadSeriesTag: Bool) {
        var source = raw
        var hadTag = false
        if let tag = seriesTag(in: raw) {
            source = tag.main + " " + tag.series
            hadTag = true
        }
        let tokens = TitleNormalizer.tokens(source, level: .articleless)
            .filter { !stopwords.contains($0) }
        return (Set(tokens), hadTag)
    }

    static func isNumeral(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    // MARK: - Score

    /// Order-free similarity of two raw titles in [0, 1] (formula in the type doc).
    static func score(_ a: String, _ b: String) -> Double {
        let (ta, tagA) = significantTokens(a)
        let (tb, tagB) = significantTokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return sameSetScore }

        let common = ta.intersection(tb).count
        let dice = 2.0 * Double(common) / Double(ta.count + tb.count)

        let aIsSmall = ta.count <= tb.count
        let (small, large, smallHadTag) = aIsSmall ? (ta, tb, tagA) : (tb, ta, tagB)
        guard small.isSubset(of: large) else { return dice }
        let extra = large.subtracting(small)
        let coverage = Double(small.count) / Double(large.count)
        guard small.count >= subsetMinTokens, coverage >= subsetMinCoverage else { return dice }
        if extra.contains(where: isNumeral), !smallHadTag { return dice }
        if !extra.isDisjoint(with: separateGameWords) { return dice }
        return max(dice, subsetBase + subsetCoverageWeight * coverage)
    }

    /// Best score of `query` against any of `names`.
    static func bestScore(query: String, names: [String]) -> Double {
        names.reduce(0.0) { max($0, score(query, $1)) }
    }
}
