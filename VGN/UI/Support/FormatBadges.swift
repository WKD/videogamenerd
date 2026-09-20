import Foundation

/// The ownership-format badges a grid tile shows (PLAN §8, owner request wave 17):
/// **one badge per distinct format among the game's really-owned copies**, in a fixed
/// order — physical (a disc) → digital (a download) → ROM (the purple chip) → PS Plus
/// (the subscription claim). The generic "Owned" box is gone: any format badge means
/// owned. A subscription-only game shows only the PS Plus badge; a game with a real
/// digital copy **and** a PS Plus claim shows both.
///
/// Pure: it reads only the per-format facts on ``GameSummary`` (populated by the grid
/// SQL) so the tile draws without a DB round-trip, and the ordering is unit-tested.
enum FormatBadgeKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case physical
    case digital
    case rom
    case psPlus

    var id: String { rawValue }
}

/// One badge to draw: its kind and the platforms of the copies it stands for (for the
/// tooltip "Physical · PS3", "Digital · PS5, PC").
struct FormatBadge: Sendable, Hashable, Identifiable {
    var kind: FormatBadgeKind
    var platformIDs: [String]
    var id: FormatBadgeKind { kind }
}

enum FormatBadges {
    /// The **real ownership-format** badges for a game, in draw order — physical → digital
    /// → ROM. Empty when the game owns no real copy. PS Plus is **not** here: it is a
    /// licence, not a format, and draws in the cover's top-left corner (owner, wave 19 —
    /// ``licensing(for:)``). So a PS-Plus-only game shows no format badge (unchanged), and
    /// the bottom row is at most four (physical + digital + ROM + played).
    static func badges(for game: GameSummary) -> [FormatBadge] {
        var out: [FormatBadge] = []
        if game.hasPhysical { out.append(FormatBadge(kind: .physical, platformIDs: game.physicalPlatformIDs)) }
        if game.hasDigital { out.append(FormatBadge(kind: .digital, platformIDs: game.digitalPlatformIDs)) }
        if game.hasROM || !game.romPlatformIDs.isEmpty {
            out.append(FormatBadge(kind: .rom, platformIDs: game.romPlatformIDs))
        }
        return out
    }

    /// The PS Plus **licensing** badge for a game, or nil (owner, wave 19). PS Plus is a
    /// licence — it sits alone in the cover's top-left corner (next to the tier chip), not
    /// in the format row — because the copy vanishes when the subscription ends (PLAN §8/§13.3).
    static func licensing(for game: GameSummary) -> FormatBadge? {
        game.hasSubscription ? FormatBadge(kind: .psPlus, platformIDs: game.subscriptionPlatformIDs) : nil
    }
}

// MARK: - Shared glyph mapping (D3)

extension FormatBadgeKind {
    /// The one SF Symbol used **everywhere** this format is drawn as an icon — the grid tile
    /// badge, the Quick Add format chip, and any format icon in the rest of the app — so they
    /// never drift apart (wave 19). Deliberately **not** the filled-circle variants
    /// (`opticaldisc.fill`, `arrow.down.circle.fill`): a filled-circle glyph painted white
    /// inside the tinted badge circle reads as a featureless white blob. These have a
    /// distinctive silhouette instead: a disc that reads as a disc, a plain download arrow,
    /// a chip.
    var symbolName: String {
        switch self {
        case .physical: return "opticaldisc"        // outline disc — a ring with a centre hole
        case .digital:  return "arrow.down.to.line"  // the download glyph, not a circled dot
        case .rom:      return "memorychip"          // a cartridge chip
        case .psPlus:   return "sparkles"            // unused: PS Plus draws the `PSPlusBadge` asset
        }
    }
}

extension ProductFormat {
    /// The badge kind for a stored copy format, so the format chips/icons that speak
    /// ``ProductFormat`` (Quick Add, filters) share the grid badges' one glyph set (D3).
    var badgeKind: FormatBadgeKind {
        switch self {
        case .physical: return .physical
        case .digital:  return .digital
        case .rom:      return .rom
        }
    }
}

// MARK: - Grid badge row geometry (D1)

/// Geometry for a grid tile's format-badge row (PLAN §8). Defined once so the ``GameCell``
/// view and the overflow test agree: the badge diameter and inter-badge spacing scale gently
/// with the tile width, and the row **wraps to a second line** rather than overflow the
/// narrowest tile with the worst case (physical + digital + ROM + PS Plus + played = 5 badges).
/// Pure (Foundation only) so it is unit-testable without hosting a view.
enum FormatBadgeLayout {
    /// The grid tile width bounds (mirror ``LibraryViewModel.minCellWidth``/`maxCellWidth`).
    static let minTile: CGFloat = 110
    static let maxTile: CGFloat = 230

    /// The cell's own `.padding(6)` (both sides) plus the badge overlay's `.padding(6)`
    /// (both sides): the width the badge row loses to insets inside the tile.
    static let cellInset: CGFloat = 12
    static let badgeInset: CGFloat = 12

    /// Badge circle diameter for a tile of `cellWidth` — ~20 pt at the default 150 pt tile,
    /// bounded so it never drops below a legible 18 pt or grows past 24 pt.
    static func diameter(cellWidth: CGFloat) -> CGFloat {
        clamp((cellWidth * 0.14).rounded(), 18, 24)
    }

    /// Inter-badge spacing for a tile of `cellWidth`.
    static func spacing(cellWidth: CGFloat) -> CGFloat {
        clamp((diameter(cellWidth: cellWidth) * 0.18).rounded(), 3, 5)
    }

    /// The width available to the badge row inside the tile (the cover width minus insets).
    static func availableWidth(cellWidth: CGFloat) -> CGFloat {
        cellWidth - cellInset - badgeInset
    }

    /// How many badges fit on one line at `cellWidth`.
    static func perLine(cellWidth: CGFloat) -> Int {
        let d = diameter(cellWidth: cellWidth)
        let s = spacing(cellWidth: cellWidth)
        let avail = availableWidth(cellWidth: cellWidth)
        // n·d + (n−1)·s ≤ avail  ⇒  n ≤ (avail + s) / (d + s)
        return max(1, Int((avail + s) / (d + s)))
    }

    /// The rendered width of a single line of `count` badges.
    static func lineWidth(count: Int, cellWidth: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let d = diameter(cellWidth: cellWidth)
        let s = spacing(cellWidth: cellWidth)
        return CGFloat(count) * d + CGFloat(count - 1) * s
    }

    /// True when a row of `count` badges never draws wider than the tile — the row wraps, so
    /// each wrapped line (at most ``perLine(cellWidth:)`` badges) stays within the available
    /// width. The worst case is `count == 5` at ``minTile``.
    static func fits(count: Int, cellWidth: CGFloat) -> Bool {
        let onLine = min(count, perLine(cellWidth: cellWidth))
        return lineWidth(count: onLine, cellWidth: cellWidth) <= availableWidth(cellWidth: cellWidth) + 0.5
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
