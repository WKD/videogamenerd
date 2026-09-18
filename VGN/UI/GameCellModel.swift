import CoreGraphics
import Observation

/// The small per-cell observable box (PLAN §9: "each cell observes its own
/// `@Observable` box … a tick re-renders one cell, not the grid").
///
/// A cell reads `summary` and `thumbnail` from *its* box. When a cover finishes
/// loading it writes `thumbnail` here — only this cell re-renders, the grid
/// never re-diffs. `update(_:)` deliberately mutates only on a real change so an
/// unchanged row in a re-yielded games array doesn't invalidate its cell.
@MainActor
@Observable
final class GameCellModel: Identifiable {
    /// Stable id (a cell box is keyed by game id and never re-homed), kept as a
    /// `nonisolated let` so `Identifiable` conformance needs no actor hop.
    nonisolated let id: Int64
    var summary: GameSummary
    /// The downsampled cover, once the loader delivers it (nil = placeholder).
    var thumbnail: CGImage?

    init(summary: GameSummary, thumbnail: CGImage? = nil) {
        self.id = summary.id
        self.summary = summary
        self.thumbnail = thumbnail
    }

    /// Adopt a fresh summary, invalidating the cell only when something changed.
    func update(_ new: GameSummary) {
        guard summary != new else { return }
        summary = new
    }
}
