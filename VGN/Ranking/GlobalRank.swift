import Foundation

/// Derives the numbered global chart (#1…#N) across all tiers for placed games,
/// and a filtered chart for a subset (e.g. "PS2 games") that reports both the
/// derived position within the subset and the true global position.
enum GlobalRank {

    /// One row of the global chart. `position` is 1…N over placed games only;
    /// unplaced games are excluded (they are unnumbered).
    struct Row: Equatable, Sendable {
        var id: GameID
        var tier: TierID
        var position: Int
    }

    /// The full global order: tiers by `sort`, games within a tier by key.
    static func chart(_ snapshot: RankSnapshot) -> [Row] {
        var rows: [Row] = []
        var position = 0
        for slice in snapshot.orderedTiers {
            for item in slice.placed {
                position += 1
                rows.append(Row(id: item.id, tier: slice.tier, position: position))
            }
        }
        return rows
    }

    /// One row of a filtered chart (derived chart for a subset of games).
    struct FilteredRow: Equatable, Sendable {
        var id: GameID
        var tier: TierID
        /// Rank within the filtered subset, 1…k.
        var derivedPosition: Int
        /// Rank in the full global chart, 1…N.
        var globalPosition: Int
    }

    /// The chart restricted to `subset`, preserving global order. Each surviving
    /// row carries its derived (1…k) and global (1…N) positions. Ids not present
    /// in the snapshot's placed games are ignored.
    static func filteredChart(_ snapshot: RankSnapshot, subset: Set<GameID>) -> [FilteredRow] {
        var rows: [FilteredRow] = []
        var derived = 0
        for row in chart(snapshot) where subset.contains(row.id) {
            derived += 1
            rows.append(FilteredRow(
                id: row.id,
                tier: row.tier,
                derivedPosition: derived,
                globalPosition: row.position
            ))
        }
        return rows
    }
}
