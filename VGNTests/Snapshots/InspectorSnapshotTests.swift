#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The inspector (PLAN §8): single game with copies / playtime / score line,
/// multi-select, and the empty state.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
struct InspectorSnapshotTests {
    private let group = "02 Inspector"
    private let size = SnapSize(width: 320, height: 700)

    @Test func single() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1])
        await SnapshotHarness.capture(group: group, "inspector-single", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    @Test func multi() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1, 2, 3])
        await SnapshotHarness.capture(group: group, "inspector-multi", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    @Test func empty() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: group, "inspector-empty", size: size) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    // MARK: Seeded rich detail (playtime table + PSN + summary · ⚠︎ estimate · compilation
    // caption · PS Plus copy · stacked actions) — via a fake data source carrying a full
    // `GameDetail` the sample source can't build.

    /// A rich `GameDetail`: manual playtime (wins) + PSN reference, all three estimates with a
    /// deliberately inflated completionist so the ⚠︎ suspicious row shows, a compilation copy
    /// with a collection-playtime caption, and a PS Plus copy.
    private static func richDetail() -> GameDetail {
        GameDetail(
            id: 1, igdbID: 999, title: "Metal Gear Solid 2: Sons of Liberty", sortTitle: "metal gear solid 2",
            summary: "Raiden infiltrates the Big Shell.", releaseDate: nil, year: 2001, decade: 2000,
            played: true, owned: true, status: .playing,
            tierID: 1, tierLetter: "S", tierLabel: "Masterpiece", tierColorHex: "#FF7F7F", rankKey: RankKey(100),
            coverFile: nil, igdbCoverImageID: nil,
            genres: ["Stealth", "Action"], platformIDs: ["ps3", "ps4"],
            myPlaytimeS: 40 * 3600, psnPlaytimeS: 75 * 3600,
            ttbHastilyS: 27 * 3600, ttbNormallyS: 32 * 3600, ttbCompletelyS: 1000 * 3600,
            ttbSource: "igdb", addedAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_650_000_000),
            copies: [
                GameDetail.Copy(productID: 2, platformID: "ps3", format: .physical, kind: .compilation,
                                title: "Metal Gear Solid: The Legacy Collection", source: .manual,
                                position: 0, memberCount: 3, memberTitles: ["MGS 2", "MGS 3", "MGS 4"],
                                memberIDs: [10, 11, 12], collectionPlaytimeS: 75 * 3600),
                GameDetail.Copy(productID: 3, platformID: "ps4", format: .digital, kind: .single,
                                source: .psn, subscription: .psPlus, position: 1, memberCount: 1),
            ])
    }

    /// Forwards to a preview source but returns one rich `GameDetail` for id 1.
    private struct SeededDetailSource: LibraryDataSource {
        var base: PreviewLibraryDataSource
        var detail: GameDetail
        var summary: GameSummary
        func gameDetail(id: Int64) async -> GameDetail? { id == detail.id ? detail : nil }
        func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> { onceStream(id == detail.id ? detail : nil) }
        func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> { onceStream([summary]) }
        func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> { base.sidebarCounts(pace: pace, style: style) }
        func platformsInUse() -> AsyncStream<[PlatformInfo]> { base.platformsInUse() }
        func tiers() -> AsyncStream<[TierInfo]> { onceStream(TierInfo.defaultTiers) }
        func genresInUse() -> AsyncStream<[String]> { base.genresInUse() }
        func decadesInUse() -> AsyncStream<[Int]> { base.decadesInUse() }
    }

    @Test func seededDetail() async {
        let detail = Self.richDetail()
        let summary = GameSummary(id: 1, title: detail.title, year: detail.year,
                                  tierID: 1, tierLetter: "S", tierColorHex: "#FF7F7F",
                                  played: true, owned: true, platformIDs: detail.platformIDs)
        let source = SeededDetailSource(base: PreviewLibraryDataSource(games: [summary]),
                                        detail: detail, summary: summary)
        let vm = LibraryViewModel(dataSource: source)
        vm.start()
        await SnapshotHarness.settle(rounds: 8)
        vm.selectedGameIDs = [1]
        await SnapshotHarness.settle(rounds: 8)
        await SnapshotHarness.capture(group: group, "inspector-detail-rich",
                                      size: SnapSize(width: 320, height: 1500)) {
            InspectorView(vm: vm).frame(width: 300)
        }
    }

    // MARK: Estimate-warning dismissed state + the action row at 440 pt (the wide layout the
    // 300 pt pane above can't show).

    @Test func estimateWarningDismissed() async {
        await SnapshotHarness.capture(group: group, "inspector-estimate-dismissed",
                                      size: SnapSize(width: 320, height: 120), settle: 4) {
            PlaytimeEstimateWarning(
                reason: "Completionist (1000 h) is more than 4× the main story (32 h).",
                dismissed: true, isRefreshing: false, onRefresh: {}, onDismissToggle: { _ in })
                .padding().frame(width: 300)
        }
    }

    /// The common linked-game action set; `ViewThatFits` rows it when there is room and stacks
    /// it (one full-width button per line) when the column is at its 300 pt minimum.
    private var inspectorActions: [InspectorAction] {
        [InspectorAction(title: "Link to IGDB…", systemImage: "link", help: "", action: {}),
         InspectorAction(title: "Refresh metadata", systemImage: "arrow.clockwise", help: "", action: {}),
         InspectorAction(title: "Choose Cover…", systemImage: "photo.stack", help: "", action: {})]
    }

    @Test func actionsRowWide() async {
        await SnapshotHarness.capture(group: group, "inspector-actions-row",
                                      size: SnapSize(width: 480, height: 100), settle: 4) {
            InspectorActionsView(actions: inspectorActions).frame(width: 440).padding()
        }
    }

    @Test func actionsStackedNarrow() async {
        await SnapshotHarness.capture(group: group, "inspector-actions-stacked",
                                      size: SnapSize(width: 320, height: 200), settle: 4) {
            InspectorActionsView(actions: inspectorActions).frame(width: 300).padding()
        }
    }
}
#endif
