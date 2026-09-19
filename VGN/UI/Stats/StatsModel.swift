import Observation
import SwiftUI

/// The `@MainActor @Observable` store behind the Library Stats window (PLAN §6.4).
/// Loads a ``LibraryStatsReport`` for the chosen scope and reloads whenever the
/// library changes (a GRDB change signal, re-queried — the same "emission is a
/// signal, re-read" pattern the ranking views use). Nothing here is written from a
/// SwiftUI `body`; scope changes come from the picker's binding (a user action).
@MainActor
@Observable
final class StatsModel {
    private(set) var report: LibraryStatsReport
    /// True until the first report has loaded.
    private(set) var isLoading = true
    private(set) var scope: StatsScope

    private let store: LibraryStatsStore
    private var liveTask: Task<Void, Never>?
    /// Bumped per reload so an out-of-order finish never overwrites a newer one.
    private var loadToken = 0

    init(store: LibraryStatsStore, scope: StatsScope = .all) {
        self.store = store
        self.scope = scope
        self.report = .empty(scope: scope)
    }

    /// Load the first report and start observing library changes.
    func start() async {
        await reload()
        subscribeLive()
    }

    /// Stop observing (window closed).
    func stop() {
        liveTask?.cancel()
        liveTask = nil
    }

    /// Switch scope from the picker (a user action, not a `body` write).
    func setScope(_ new: StatsScope) {
        guard new != scope else { return }
        scope = new
        Task { await reload() }
    }

    /// A binding the segmented picker drives.
    var scopeBinding: Binding<StatsScope> {
        Binding(get: { self.scope }, set: { self.setScope($0) })
    }

    private func reload() async {
        loadToken &+= 1
        let token = loadToken
        let scope = self.scope
        let fresh = try? await store.report(scope: scope)
        // Only apply if this is still the latest request and the scope is current.
        guard token == loadToken, let fresh, fresh.scope == self.scope else { return }
        report = fresh
        isLoading = false
    }

    #if DEBUG
    /// Pin the model to a fixed report (previews / snapshots — no observation).
    func applyPreview(_ report: LibraryStatsReport) {
        self.report = report
        self.scope = report.scope
        self.isLoading = false
    }
    #endif

    private func subscribeLive() {
        guard liveTask == nil else { return }
        liveTask = Task { [store] in
            do {
                // Each emission (including the immediate initial one) is a "something
                // changed" signal — re-query for the current scope. The initial
                // emission just repeats `start()`'s load, which is idempotent.
                for try await _ in store.changeSignal() {
                    await self.reload()
                }
            } catch {
                // Observation ended (cancelled) — nothing to do.
            }
        }
    }
}
