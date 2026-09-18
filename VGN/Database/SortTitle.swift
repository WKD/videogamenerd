import Foundation

/// Computes a `sort_title` by stripping leading articles (English + French) and
/// folding case/diacritics, so "The Last of Us" sorts under L and
/// "Les Chevaliers de Baphomet" under C.
///
/// This is a deliberately simple local implementation. A richer normaliser
/// (roman numerals, ™/®, subtitle handling) lands in `VGN/Matching/` from
/// another lane.
enum SortTitle {
    // TODO(merge): use TitleNormalizer from VGN/Matching once it lands.
    private static let leadingArticles: [String] = [
        "the ", "a ", "an ",
        "le ", "la ", "les ", "l'", "un ", "une ", "des ", "du ", "de ",
    ]

    static func make(from title: String) -> String {
        var s = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        for article in leadingArticles where s.hasPrefix(article) {
            s = String(s.dropFirst(article.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
