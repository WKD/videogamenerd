import CoreGraphics

/// Which side of the hovered row the insertion line hugs (PLAN §7 — The Top
/// reorder feedback). `.above` when the pointer is in the upper half of a row,
/// `.below` in the lower half.
enum TopInsertionEdge: Equatable, Sendable {
    case above
    case below
}

/// A resolved reorder target for The Top: where the insertion line is drawn
/// (`anchorID` + `edge`) **and** the move it maps to (`toTier` + `gap`). One value
/// drives both the hover feedback and the drop, so the game always lands exactly
/// where the line showed. `nil` means "no valid target here" (a no-op position, or
/// nothing is being dragged).
struct TheTopDropTarget: Equatable, Sendable {
    /// The display item the line is anchored to (`TopDisplayItem.id`, e.g. "g12" / "d3").
    var anchorID: String
    /// The edge of `anchorID` the line hugs.
    var edge: TopInsertionEdge
    /// The tier the game lands in (crossing a divider changes the tier — PLAN §7).
    var toTier: Int64
    /// Insertion gap among `toTier`'s placed rows, in *displayed* order
    /// (0 = before the first, `placedCount` = after the last) — the same space
    /// `TheTopModel.reorder(gameID:toTier:gap:)` / `TierBoardModel.planDrop` consume.
    var gap: Int
    /// True when the destination tier differs from the dragged game's current tier
    /// (drives the destination-tier colour hint on the line).
    var crossesTier: Bool
    /// The destination tier id (== `toTier`; kept explicit for the colour lookup).
    var destinationTierID: Int64
}

/// Pure geometry for The Top's insertion line (PLAN §7 — Finder/Music-style
/// reorder feedback). Foundation/CoreGraphics only, no SwiftUI: given the flat
/// list of slots (dividers + games, in chart order), the hovered slot and which
/// half of it the pointer is in, it returns the one insertion target — or `nil`
/// for a no-op (dropping a game directly above or below itself). The view and the
/// drop both go through `resolve`, so the line and the landing spot cannot diverge.
enum TheTopDropGeometry {

    /// A flat slot in the chart, mirroring one `TopDisplayItem`.
    enum Slot: Equatable, Sendable {
        /// A tier divider row (`id` = its `TopDisplayItem.id`).
        case divider(id: String, tierID: Int64)
        /// A game row. `placedIndex` is the game's index among its tier's placed
        /// rows, or `nil` for an unplaced (dimmed, unnumbered) tail game.
        case game(id: String, gameID: Int64, tierID: Int64, placedIndex: Int?)

        var anchorID: String {
            switch self {
            case .divider(let id, _): return id
            case .game(let id, _, _, _): return id
            }
        }
    }

    /// Upper half ⇒ `.above`, lower half ⇒ `.below`. A zero/negative height (not
    /// yet measured) falls back to `.above` so an early callback never mis-fires.
    static func edge(locationY: CGFloat, rowHeight: CGFloat) -> TopInsertionEdge {
        guard rowHeight > 0 else { return .above }
        return locationY >= rowHeight / 2 ? .below : .above
    }

    /// Resolve a hover over `slots[hoveredIndex]` into the single insertion target,
    /// or `nil` if it is a no-op for `draggedID`. Crossing a divider is never a
    /// no-op (the tier changes); a same-tier drop directly beside the dragged
    /// game's own slot is.
    static func resolve(slots: [Slot], hoveredIndex: Int,
                        edge: TopInsertionEdge, draggedID: Int64) -> TheTopDropTarget? {
        guard slots.indices.contains(hoveredIndex) else { return nil }

        // The dragged game's current tier + placed index (drag starts only from a
        // placed row, but tolerate absence).
        var sourceTier: Int64?
        var sourceIndex: Int?
        for slot in slots {
            if case let .game(_, gameID, tierID, placedIndex) = slot, gameID == draggedID {
                sourceTier = tierID
                sourceIndex = placedIndex
            }
        }

        let flatGap = hoveredIndex + (edge == .below ? 1 : 0)
        guard let dest = destination(slots: slots, flatGap: flatGap) else { return nil }

        // No-op: same tier, and the gap is either side of the game's own slot.
        if let st = sourceTier, st == dest.toTier, let si = sourceIndex,
           dest.gap == si || dest.gap == si + 1 {
            return nil
        }

        let crosses = sourceTier != nil && sourceTier != dest.toTier
        return TheTopDropTarget(anchorID: slots[hoveredIndex].anchorID, edge: edge,
                                toTier: dest.toTier, gap: dest.gap,
                                crossesTier: crosses, destinationTierID: dest.toTier)
    }

    /// Map a flat gap `g` (0…count) to a `(toTier, gap-within-tier)` destination.
    /// A gap that sits just before a divider is the *end of the tier above*
    /// (last of the upper tier); just after a divider is the *start of the tier
    /// below* (first of the lower tier) — PLAN §7.
    static func destination(slots: [Slot], flatGap g: Int) -> (toTier: Int64, gap: Int)? {
        let count = slots.count
        guard g >= 0, g <= count else { return nil }
        let after = g < count ? slots[g] : nil
        let before = g > 0 ? slots[g - 1] : nil

        if let after {
            switch after {
            case .game(_, _, let tierID, let placedIndex):
                // Insert before this game: its own placed index, or the end of the
                // tier's placed rows when it is an unplaced tail game.
                return (tierID, placedIndex ?? placedCount(slots, tierID))
            case .divider(_, let tierID):
                // Gap right before a divider ⇒ end of the tier above it.
                if case let .game(_, _, upperTier, _)? = before {
                    return (upperTier, placedCount(slots, upperTier))
                }
                // Top of the list (before the first divider) ⇒ first of that tier.
                return (tierID, 0)
            }
        }
        // End of the list ⇒ after the last game of its tier.
        if case let .game(_, _, tierID, _)? = before {
            return (tierID, placedCount(slots, tierID))
        }
        return nil
    }

    /// Number of placed games in `tierID` across the slots.
    static func placedCount(_ slots: [Slot], _ tierID: Int64) -> Int {
        slots.reduce(0) { acc, slot in
            if case let .game(_, _, tier, placedIndex) = slot, tier == tierID, placedIndex != nil {
                return acc + 1
            }
            return acc
        }
    }
}
