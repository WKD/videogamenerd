import Foundation

/// Computes a `sort_title`: a folded, article-stripped, human-sensible key so
/// "The Last of Us" sorts under L and "Les Chevaliers de Baphomet" under C.
///
/// Built from the shared, tested stages of `TitleNormalizer` (`VGN/Matching/`) —
/// case/diacritic folding + tag stripping, the "Zelda, The" comma-article form,
/// canonicalisation (`&`→`and`, roman→arabic numerals, punctuation → space) and
/// leading-article removal (English **and** French).
///
/// It deliberately stops short of `TitleNormalizer`'s looser levels: it does
/// **not** strip edition/budget tags and does **not** drop subtitles, because a
/// sort key must stay recognisable and must keep distinct games apart — a
/// remaster/edition is a separate game (PLAN §4). Numerals are *normalised, not
/// collapsed*: "Final Fantasy VII" and "VIII" become 7 and 8, still distinct and
/// still adjacent.
///
/// Finally, each run of digits is zero-padded so numbers sort **naturally**
/// ("Final Fantasy 2" < "Final Fantasy 10", not lexically 10 < 2).
enum SortTitle {
    /// Width to zero-pad digit runs to. 8 digits covers any game number or year
    /// without ever colliding at a personal-library scale.
    private static let numberPadWidth = 8

    static func make(from title: String) -> String {
        var s = TitleNormalizer.foldBasics(title)        // fold, drop (Europe)/[!] tags, dashes/quotes
        s = TitleNormalizer.removeCommaArticle(s)        // "Zelda, The" → "Zelda"
        s = TitleNormalizer.canonicalize(s)              // &→and, roman→arabic, punctuation → space
        s = TitleNormalizer.stripLeadingArticle(s)       // "the last of us" → "last of us"
        s = padNumbers(in: s)                            // natural numeric ordering
        return TitleNormalizer.collapse(s).trimmingCharacters(in: .whitespaces)
    }

    /// Zero-pad every maximal run of ASCII digits to a fixed width.
    private static func padNumbers(in s: String) -> String {
        var out = ""
        var digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            // Trim to the pad width from the left only if it somehow exceeds it
            // (never happens for real titles); otherwise left-pad with zeros.
            if digits.count >= numberPadWidth {
                out += digits
            } else {
                out += String(repeating: "0", count: numberPadWidth - digits.count) + digits
            }
            digits = ""
        }
        for ch in s {
            if ch.isNumber && ch.isASCII {
                digits.append(ch)
            } else {
                flush()
                out.append(ch)
            }
        }
        flush()
        return out
    }
}
