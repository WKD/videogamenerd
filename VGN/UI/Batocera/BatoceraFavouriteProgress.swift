import Foundation

/// The shared, observable progress of the background "match my favourites" run (D4, PLAN §15).
///
/// The favourites pass lives in ``BatoceraImportPresenter`` but the owner watches it from
/// Settings ▸ Batocera ("Matching favourites… 120 of 247 · Stop"). Rather than have the two
/// objects poll each other, both hold the **same** instance: the presenter drives it, the
/// settings model reads it and calls ``stop()``. No timers, no polling — the values change only
/// when a batch finishes, so an idle app stays idle (PLAN §8 CPU rule).
@MainActor
@Observable
final class BatoceraFavouriteProgress {
    /// Whether a run is in flight (drives the Settings status line + Stop button).
    private(set) var isRunning = false
    /// Favourites attempted so far this run.
    private(set) var matched = 0
    /// Favourites to match when the run began (fixed for the run).
    private(set) var total = 0
    /// Favourites added to the library so far this run.
    private(set) var added = 0

    /// Cancels the in-flight run (the presenter wires this to its task's `cancel()`).
    @ObservationIgnored var onStop: () -> Void = {}

    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(matched) / Double(total))
    }

    /// The Settings status line ("Matching favourites… 120 of 247"), or nil when idle.
    var statusLine: String? {
        isRunning ? "Matching favourites… \(matched) of \(total)" : nil
    }

    func begin(total: Int) {
        self.total = total
        matched = 0
        added = 0
        isRunning = true
    }

    func update(matched: Int, added: Int) {
        self.matched = matched
        self.added = added
    }

    func finish() { isRunning = false }

    /// The Settings "Stop" button: end the run cleanly (the already-matched favourites are kept;
    /// the rest wait for the next sync/launch).
    func stop() { onStop() }
}
