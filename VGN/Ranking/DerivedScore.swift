import Foundation

/// A rank-derived 1–10 score, computed on demand and **never stored, never typed**
/// (PLAN §7 extension). `value` is the full-precision score (kept exact so the
/// global list is strictly decreasing); formatting rounds to one decimal.
struct DerivedScoreValue: Hashable, Sendable {
    /// Full-precision score in the 1.0…10.0 range.
    var value: Double
    /// True for an unplaced game (band midpoint) — the UI shows "~8.5".
    var isApproximate: Bool

    init(value: Double, isApproximate: Bool) {
        self.value = value
        self.isApproximate = isApproximate
    }

    /// One-decimal, with the locale's decimal separator; "~" prefix if approximate.
    func formatted(locale: Locale = .current) -> String {
        let rounded = (value * 10).rounded() / 10
        var text = String(format: "%.1f", rounded)          // C locale → dot
        if let sep = locale.decimalSeparator, sep != "." {
            text = text.replacingOccurrences(of: ".", with: sep)
        }
        return isApproximate ? "~\(text)" : text
    }

    /// One decimal with a dot, for CSV (locale-independent).
    var csvString: String { String(format: "%.1f", (value * 10).rounded() / 10) }
}

/// Turns a ranking into 1–10 scores (PLAN §7 extension). Pure — Foundation only.
///
/// **Bands** are the score range each tier occupies, keyed by the tier's *sort
/// order* (first tier = top band). For exactly six tiers the canonical bands are
/// used (S 9.0–10.0 · A 8.0–8.9 · B 7.0–7.9 · C 5.5–6.9 · D 3.0–5.4 · F 1.0–2.9);
/// they are deliberately non-overlapping, so the global list is strictly
/// decreasing across every tier boundary. For any other tier count the full
/// 1.0…10.0 scale is divided into that many **equal** contiguous bands, top-first
/// — the documented fallback rule.
///
/// A placed game's score is a linear interpolation from the band's top (the first
/// game in the tier) to its bottom (the last). A lone placed game sits at the
/// band midpoint. An unplaced game is the band midpoint, flagged approximate.
enum DerivedScore {

    /// (high, low) per tier for exactly six tiers.
    static let canonicalSixBands: [(high: Double, low: Double)] = [
        (10.0, 9.0), (8.9, 8.0), (7.9, 7.0), (6.9, 5.5), (5.4, 3.0), (2.9, 1.0),
    ]

    static let scaleTop = 10.0
    static let scaleBottom = 1.0

    /// The (high, low) band for each tier, in sort order (index 0 = top tier).
    static func bands(tierCount n: Int) -> [(high: Double, low: Double)] {
        guard n > 0 else { return [] }
        if n == 6 { return canonicalSixBands }
        let span = (scaleTop - scaleBottom) / Double(n)
        var result: [(high: Double, low: Double)] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let high = scaleTop - Double(i) * span
            let low = scaleTop - Double(i + 1) * span
            result.append((high: high, low: low))
        }
        return result
    }

    /// The score of the placed game at `position` (0 = top) among `count` placed
    /// games in a tier whose band is `band`.
    static func placedScore(band: (high: Double, low: Double), position: Int, count: Int) -> Double {
        guard count > 1 else { return (band.high + band.low) / 2 }   // lone → midpoint
        let t = Double(position) / Double(count - 1)                 // 0 at top → 1 at bottom
        return band.high - (band.high - band.low) * t
    }

    static func bandMidpoint(_ band: (high: Double, low: Double)) -> Double {
        (band.high + band.low) / 2
    }

    /// Every game's score from a snapshot (placed by interpolation, unplaced at the
    /// band midpoint and flagged approximate).
    static func scores(_ snapshot: RankSnapshot) -> [GameID: DerivedScoreValue] {
        let ordered = snapshot.orderedTiers
        let bandList = bands(tierCount: ordered.count)
        var out: [GameID: DerivedScoreValue] = [:]
        for (i, slice) in ordered.enumerated() {
            let band = bandList[i]
            let count = slice.placed.count
            for (j, item) in slice.placed.enumerated() {
                out[item.id] = DerivedScoreValue(
                    value: placedScore(band: band, position: j, count: count), isApproximate: false)
            }
            let mid = bandMidpoint(band)
            for id in slice.unplaced {
                out[id] = DerivedScoreValue(value: mid, isApproximate: true)
            }
        }
        return out
    }

    /// One game's score, or nil if it is not tiered in the snapshot.
    static func score(for gameID: GameID, in snapshot: RankSnapshot) -> DerivedScoreValue? {
        scores(snapshot)[gameID]
    }
}
