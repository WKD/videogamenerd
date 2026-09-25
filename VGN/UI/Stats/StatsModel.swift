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
    /// The owner's play style, for planning figures (the backlog estimate). Read from the
    /// same persisted preference the BY LENGTH shelves use, and re-read when it changes so
    /// the Stats window reacts like the shelves do (D4, owner request 2026-09-20).
    private let playStyleProvider: @MainActor () -> PlayStyle
    /// The owner's manual pace-factor override (nil = use the factor measured from the
    /// library, which the store computes in the same read). Re-read on each reload.
    private let paceOverrideProvider: @MainActor () -> Double?
    private var paceObserver: (any NSObjectProtocol)?
    private var liveTask: Task<Void, Never>?
    private var styleObserver: (any NSObjectProtocol)?
    /// Bumped per reload so an out-of-order finish never overwrites a newer one.
    private var loadToken = 0

    init(store: LibraryStatsStore, scope: StatsScope = .all,
         playStyleProvider: @escaping @MainActor () -> PlayStyle
            = { UserDefaultsPlayPacePreferences().playStyle() },
         paceOverrideProvider: @escaping @MainActor () -> Double?
            = { UserDefaultsPlayPacePreferences().paceFactorOverride() }) {
        self.store = store
        self.scope = scope
        self.playStyleProvider = playStyleProvider
        self.paceOverrideProvider = paceOverrideProvider
        self.report = .empty(scope: scope)
    }

    /// Load the first report and start observing library + play-style changes.
    func start() async {
        await reload()
        subscribeLive()
        subscribeStyle()
    }

    /// Stop observing (window closed).
    func stop() {
        liveTask?.cancel()
        liveTask = nil
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
            self.styleObserver = nil
        }
        if let paceObserver {
            NotificationCenter.default.removeObserver(paceObserver)
            self.paceObserver = nil
        }
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
        let style = playStyleProvider()
        let override = paceOverrideProvider()
        let fresh = try? await store.report(scope: scope, playStyle: style, paceFactorOverride: override)
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

    /// Re-query when the owner changes their play style (the backlog estimate depends on
    /// it), mirroring how the BY LENGTH shelves react (D4).
    private func subscribeStyle() {
        // The personal pace factor (PLAN §7b) moves the backlog estimate too.
        if paceObserver == nil {
            paceObserver = NotificationCenter.default.addObserver(
                forName: .vgnPaceFactorDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.reload() }
            }
        }
        guard styleObserver == nil else { return }
        styleObserver = NotificationCenter.default.addObserver(
            forName: .vgnPlayStyleDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
    }

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
