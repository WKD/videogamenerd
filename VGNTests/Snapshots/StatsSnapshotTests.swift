#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Off-screen renders of the Library Stats window (PLAN §6.4), light + dark:
/// the full dashboard with sample data and its empty state. New cases only —
/// no existing reference is re-recorded. Gated off the default `xcodebuild test`
/// like every snapshot suite (see `docs/snapshots.md`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
struct StatsSnapshotTests {
    private let group = "11 Library Stats"

    @Test func dashboardSample() async {
        let model = StatsModel(previewReport: .sample)
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "stats-dashboard",
                                      size: SnapSize(width: 980, height: 760), settle: 4) {
            StatsDashboardView(model: model)
        }
    }

    @Test func dashboardEmpty() async {
        let model = StatsModel(previewReport: .empty())
        await SnapshotHarness.capture(group: group, "stats-dashboard-empty",
                                      size: SnapSize(width: 700, height: 500), settle: 3) {
            StatsDashboardView(model: model)
        }
    }
}
#endif
