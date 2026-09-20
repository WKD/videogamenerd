import Foundation

/// Drives the background IGDB **trait-matching pass** for PS Plus Vault entries (PLAN §16) and
/// backs the Settings ▸ PlayStation status line ("Vault: 212 of 310 matched · next batch at the
/// next sync") + the "Match more now" button. Runs one capped ``VaultTraitMatcher`` batch at a
/// time — after a PSN sync, once at launch, and on demand — never overlapping. Built only in
/// **live mode with IGDB configured** (``PSNImportBuilder``); nil (and inert) everywhere else,
/// so sample / seeded / test modes make no requests.
///
/// `@MainActor @Observable`; unit-tested with a fake matcher over an in-memory database.
@MainActor
@Observable
final class VaultTraitMatchModel {
    private let catalog: RomCatalogStore
    private let matcher: VaultTraitMatcher

    private(set) var matched = 0
    private(set) var total = 0
    private(set) var isRunning = false
    private(set) var hasLoaded = false

    @ObservationIgnored private var task: Task<Void, Never>?

    init(catalog: RomCatalogStore, matcher: VaultTraitMatcher) {
        self.catalog = catalog
        self.matcher = matcher
    }

    /// Whether there are any PS Plus entries to show a status for at all.
    var hasEntries: Bool { hasLoaded && total > 0 }
    /// Every present PS Plus entry has been through a match attempt.
    var allMatched: Bool { hasLoaded && total > 0 && matched >= total }

    /// The Settings status line (PLAN §16). Empty when there is nothing to show.
    var statusText: String {
        if isRunning { return "Matching PS Plus games to IGDB…" }
        guard hasEntries else { return "" }
        var line = "Vault: \(matched) of \(total) matched"
        if matched < total { line += " · next batch at the next sync" }
        return line
    }

    /// Whether "Match more now" can do anything.
    var canMatchMore: Bool { hasEntries && !isRunning && matched < total }

    /// Reload the matched / total counts from the store (on appear, after a run).
    func refresh() async {
        if let progress = try? await catalog.psnMatchProgress() {
            matched = progress.matched
            total = progress.total
            hasLoaded = true
        }
    }

    /// Run one capped batch when idle, then refresh. No-op while a run is in flight. Used at
    /// launch, after every sync, and by "Match more now". Cheap when nothing is unmatched (one
    /// local read returning no rows).
    func run(limit: Int = VaultTraitMatcher.batchCap) {
        guard !isRunning else { return }
        isRunning = true
        let matcher = self.matcher
        task = Task { [weak self] in
            _ = await matcher.run(limit: limit)
            guard let self else { return }
            await self.refresh()
            self.isRunning = false
        }
    }

    /// The Settings "Match more now" button — run one more capped batch.
    func matchMoreNow() { run() }

    /// Refresh the counts, then run one batch (the launch / after-sync entry point).
    func refreshAndRun() {
        Task { [weak self] in
            await self?.refresh()
            self?.run()
        }
    }

    func cancel() { task?.cancel(); task = nil; isRunning = false }
}
