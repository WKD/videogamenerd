import SwiftUI

/// Cross-lane hooks the ranking screens need but cannot wire themselves, because
/// the shell (`RootView`) and the library view model live in another lane. Each
/// is optional: when the container doesn't inject it, the board / Top fall back
/// to a sensible in-view behaviour (an internal filter bar, a disabled button, a
/// no-op) so this folder builds and previews on its own.
///
/// The orchestrator adds, at the `RankingPlaceholderView(selection:)` site in
/// `RootView.content`:
///
/// ```swift
/// RankingPlaceholderView(selection: vm.selection)
///     .environment(\.rankingLibraryFilter, vm.filter)
///     .environment(\.rankingActions, RankingViewActions(
///         goToDuel: { vm.select(.duel) },
///         inspect:  { id in vm.selectOnly(id); vm.showInspector() }))
/// ```
struct RankingViewActions: Sendable {
    /// Jump the sidebar to the Duel destination ("Place n games").
    var goToDuel: (@MainActor () -> Void)?
    /// Reveal a game in the library inspector (`↩` on a selected tile / row).
    var inspect: (@MainActor (Int64) -> Void)?

    init(goToDuel: (@MainActor () -> Void)? = nil,
         inspect: (@MainActor (Int64) -> Void)? = nil) {
        self.goToDuel = goToDuel
        self.inspect = inspect
    }
}

private struct RankingActionsKey: EnvironmentKey {
    static let defaultValue = RankingViewActions()
}

private struct RankingLibraryFilterKey: EnvironmentKey {
    static let defaultValue: LibraryFilter? = nil
}

extension EnvironmentValues {
    /// The shell actions (go-to-Duel, inspect). Defaults to no-ops.
    var rankingActions: RankingViewActions {
        get { self[RankingActionsKey.self] }
        set { self[RankingActionsKey.self] = newValue }
    }

    /// The library's *current* filter, so The Top can mirror it (Top PS2 / Top
    /// 90s / …). `nil` ⇒ the container hasn't wired it, and The Top shows its own
    /// in-view filter chips instead (PLAN §7).
    var rankingLibraryFilter: LibraryFilter? {
        get { self[RankingLibraryFilterKey.self] }
        set { self[RankingLibraryFilterKey.self] = newValue }
    }
}
