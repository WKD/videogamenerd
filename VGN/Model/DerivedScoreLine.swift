import Foundation

/// The inspector's ranking line for one game (PLAN §7): the derived score plus
/// its overall and within-tier positions. Foundation-only; Lane A builds it from
/// the ranking snapshot, the UI just renders it.
///
/// - placed:   "9.6 · #4 overall · A, #2 of 14"
/// - unplaced: "~8.5 · unplaced in A"  (with a "Place now" button → Duel)
/// - unranked: no line at all (`nil` — only the tier picker shows)
struct DerivedScoreLine: Sendable, Hashable {
    var score: DerivedScoreValue
    var tierLetter: String
    /// 1-based position within the tier's placed games (nil when unplaced).
    var tierPosition: Int?
    /// Placed games in this tier.
    var tierTotalPlaced: Int
    /// 1-based position over all placed games (nil when unplaced).
    var overallPosition: Int?
    /// Placed games across all tiers.
    var overallTotalPlaced: Int
    var isPlaced: Bool

    /// The full one-line text (locale-aware score).
    func summary(locale: Locale = .current) -> String {
        let s = score.formatted(locale: locale)
        if isPlaced, let overall = overallPosition, let tierPos = tierPosition {
            return "\(s) · #\(overall) overall · \(tierLetter), #\(tierPos) of \(tierTotalPlaced)"
        }
        return "\(s) · unplaced in \(tierLetter)"
    }
}
