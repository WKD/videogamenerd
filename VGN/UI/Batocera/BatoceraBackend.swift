import Foundation

/// The data seam the Batocera Settings pane, the launch auto-sync and the "Sync Now" button
/// drive (PLAN §15 phase 2), behind a protocol so the model is unit-tested against a fake
/// that never touches `/Volumes` or the database. A `Sendable` value.
///
/// **Modes.** The *live* backend wraps the real ``BatoceraSync`` actor + ``RomCatalogStore``.
/// Sample / seeded / test runs get the ``InertBatoceraBackend``, which never constructs a
/// ``BatoceraShare`` and never reads the share — every call returns a quiet, empty result.
protocol BatoceraBackend: Sendable {
    /// Whether this backend can reach a real share (false for the inert fake / non-live modes).
    var isLive: Bool { get }

    /// Run a change-detecting sync from `root`, off the main actor (``BatoceraSync`` is an
    /// actor). `skip` is the owner's editable skip list. Cancellation is honoured by the
    /// enclosing `Task`.
    func sync(root: URL, force: Bool, skip: Set<String>,
              progress: @Sendable @escaping (BatoceraSyncProgress) -> Void) async -> BatoceraSyncSummary

    /// A catalogue status snapshot for the Settings status block (never reads the share).
    func status() async -> BatoceraCatalogStatus
}

/// The live backend: the real sync actor + catalogue store over the shared database.
struct LiveBatoceraBackend: BatoceraBackend {
    let sync: BatoceraSync
    let catalog: RomCatalogStore

    var isLive: Bool { true }

    func sync(root: URL, force: Bool, skip: Set<String>,
              progress: @Sendable @escaping (BatoceraSyncProgress) -> Void) async -> BatoceraSyncSummary {
        await sync.sync(root: root, force: force, skip: skip.isEmpty ? nil : skip, progress: progress)
    }

    func status() async -> BatoceraCatalogStatus {
        (try? await catalog.statusSnapshot()) ?? .empty
    }
}

/// The inert backend for sample / seeded / test runs (PLAN §15): a sync always reports the
/// share unavailable (nothing is read, `/Volumes` is never touched) and the status is empty.
/// This is what keeps a UI smoke run or a test from ever reaching the owner's real share.
struct InertBatoceraBackend: BatoceraBackend {
    var isLive: Bool { false }

    func sync(root: URL, force: Bool, skip: Set<String>,
              progress: @Sendable @escaping (BatoceraSyncProgress) -> Void) async -> BatoceraSyncSummary {
        var summary = BatoceraSyncSummary()
        summary.shareUnavailable = true
        return summary
    }

    func status() async -> BatoceraCatalogStatus { .empty }
}
