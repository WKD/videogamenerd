import Foundation

/// A tier row (S A B C D F by default; labels and colours editable — PLAN §7).
/// Tiers are contiguous slices of the single total order, ordered by `sort`.
struct TierInfo: Hashable, Sendable, Identifiable, Codable {
    var id: Int64
    /// The single-letter badge, e.g. "S", "A".
    var letter: String
    /// Human label, e.g. "Masterpiece", "Excellent".
    var label: String
    /// Hex colour string, e.g. "#FF3B30" (no GRDB/`Color` here — UI maps it).
    var colorHex: String
    /// Order from best (0) to worst.
    var sort: Int

    init(id: Int64, letter: String, label: String, colorHex: String, sort: Int) {
        self.id = id
        self.letter = letter
        self.label = label
        self.colorHex = colorHex
        self.sort = sort
    }
}
