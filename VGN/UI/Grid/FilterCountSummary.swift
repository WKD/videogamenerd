import Foundation

/// The "N of M games" count shown at the right end of the filter-chips bar (PLAN §8,
/// owner 2026-09-20). Pure and Foundation-only, so the 0 / 1 / n forms, the missing-total
/// fallback, the multi-selection suffix and the loading state are all unit-tested.
///
/// - `shown`  — rows the grid currently shows (`LibraryViewModel.games.count`, i.e. after
///   the sidebar scope **and** every toolbar facet / search).
/// - `total`  — the size of the current sidebar scope WITHOUT the toolbar facets (the
///   sidebar count the VM already holds); nil when the scope has no such count.
/// - `selected` — the current multi-selection size (a suffix appears only for ≥ 2).
/// - `loaded` — false while the scope's first rows are still loading → show nothing.
enum FilterCountSummary {

    /// The visible count line, or nil while still loading.
    static func text(shown: Int, total: Int?, selected: Int, loaded: Bool) -> String? {
        guard loaded else { return nil }
        var line = countPhrase(shown: shown, total: total)
        if selected > 1 { line += " · \(selected) selected" }
        return line
    }

    /// "No games" / "1 of 443 games" / "37 of 443 games" / — without a total — "37 games".
    static func countPhrase(shown: Int, total: Int?) -> String {
        guard shown > 0 else { return "No games" }
        // With a total the noun agrees with the total ("1 of 443 games"); without one it
        // agrees with the count shown ("1 game").
        if let total, total >= shown {
            return "\(shown) of \(total) \(total == 1 ? "game" : "games")"
        }
        return "\(shown) \(shown == 1 ? "game" : "games")"
    }

    /// The VoiceOver label, e.g. "37 of 443 games shown, 5 selected", or nil while loading.
    static func accessibilityLabel(shown: Int, total: Int?, selected: Int, loaded: Bool) -> String? {
        guard loaded else { return nil }
        var label = countPhrase(shown: shown, total: total) + " shown"
        if selected > 1 { label += ", \(selected) selected" }
        return label
    }
}
