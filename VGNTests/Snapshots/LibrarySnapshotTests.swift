#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The main window (PLAN §8): the three panes composed by hand (see
/// `SnapSupport.mainWindow` / `docs/snapshots.md` for why `NavigationSplitView`
/// and the live `LibraryGridView` `ScrollView` can't render headless), the grid
/// content, sidebar, filter chips, cells and empty states.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LibrarySnapshotTests {
    private let group = "01 Library"

    // MARK: Composed main window (sidebar · filter chips + grid · inspector)

    @Test func mainWindowSample() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: group, "library-main-sample", size: .large) {
            SnapSupport.mainWindow(vm: vm)
        }
    }

    @Test func mainWindowCompact() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: group, "library-main-compact", size: .compact) {
            SnapSupport.mainWindow(vm: vm)
        }
    }

    @Test func mainWindowInspector() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1], inspector: true)
        await SnapshotHarness.capture(group: group, "library-main-inspector", size: .large) {
            SnapSupport.mainWindow(vm: vm, inspector: true)
        }
    }

    @Test func mainWindowMultiSelect() async {
        let vm = await SnapSupport.libraryVM(.sampled, selected: [1, 2, 3, 6], inspector: true)
        await SnapshotHarness.capture(group: group, "library-main-multiselect", size: .large) {
            SnapSupport.mainWindow(vm: vm, inspector: true)
        }
    }

    @Test func mainWindowPlatform() async {
        let vm = await SnapSupport.libraryVM(.sampled, selection: .platform("ps2"))
        await SnapshotHarness.capture(group: group, "library-main-platform", size: .large) {
            SnapSupport.mainWindow(vm: vm)
        }
    }

    @Test func mainWindowFilters() async {
        var f = LibraryFilter(scope: .all)
        f.tierIDs = [1, 2]
        f.decades = [2010, 2020]
        f.formats = [.physical]
        let vm = await SnapSupport.libraryVM(.sampled, filter: f)
        await SnapshotHarness.capture(group: group, "library-main-filters", size: .large) {
            SnapSupport.mainWindow(vm: vm)
        }
    }

    @Test func mainWindowThousand() async {
        let vm = await SnapSupport.libraryVM(SnapSupport.bigLibrarySource(1000))
        await SnapshotHarness.capture(group: group, "library-main-1000", size: .large) {
            SnapSupport.mainWindow(vm: vm, cellLimit: 120)
        }
    }

    // MARK: Grid content on its own

    @Test func gridContentSample() async {
        let vm = await SnapSupport.libraryVM(.sampled)
        await SnapshotHarness.capture(group: group, "library-grid-sample", size: .compact) {
            GridContent(vm: vm)
        }
    }

    @Test func gridContentLarge() async {
        let vm = await SnapSupport.libraryVM(SnapSupport.bigLibrarySource(400))
        await SnapshotHarness.capture(group: group, "library-grid-large", size: .large) {
            GridContent(vm: vm, limit: 120)
        }
    }

    // MARK: Real empty states (the live `LibraryGridView`; its empty path has no
    // ScrollView, so it renders headless without the populated-grid hang).

    @Test func gridEmptyLibrary() async {
        let vm = await SnapSupport.libraryVM(.empty)
        await SnapshotHarness.capture(group: group, "library-empty", size: .compact) {
            LibraryGridView(vm: vm)
        }
    }

    @Test func gridEmptyFilterResult() async {
        var f = LibraryFilter(scope: .all)
        f.tierIDs = [6]
        f.decades = [1970]
        let vm = await SnapSupport.libraryVM(.sampled, filter: f)
        await SnapshotHarness.capture(group: group, "library-empty-filter", size: .compact) {
            LibraryGridView(vm: vm)
        }
    }

    // MARK: Sidebar

    @Test func sidebar() async {
        let vm = await SnapSupport.libraryVM(SnapSupport.bigLibrarySource(400))
        await SnapshotHarness.capture(group: group, "library-sidebar",
                                      size: SnapSize(width: 260, height: 640)) {
            SidebarView(vm: vm).frame(width: 240)
        }
    }

    // MARK: Filter chips bar

    @Test func filterChips() async {
        var f = LibraryFilter(scope: .all)
        f.searchText = "souls"
        f.genres = ["RPG", "Adventure"]
        f.tierIDs = [1, 2]
        f.formats = [.rom, .physical]
        f.platforms = ["ps4", "snes"]
        let vm = await SnapSupport.libraryVM(.sampled, filter: f)
        await SnapshotHarness.capture(group: group, "library-filter-chips",
                                      size: SnapSize(width: 660, height: 120), settle: 4) {
            FilterChipsBar(vm: vm).frame(width: 640).padding(8)
        }
    }

    // MARK: Cells

    @Test func cellStates() async {
        await SnapshotHarness.capture(group: group, "library-cells",
                                      size: SnapSize(width: 560, height: 620), settle: 4) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180))], spacing: 14) {
                ForEach(GameSummary.samples) { gameSummary in
                    GameCell(model: GameCellModel(summary: gameSummary),
                             coverLoader: NoopCoverLoader(),
                             isSelected: gameSummary.id == 2)
                }
            }
            .padding()
            .frame(width: 520)
        }
    }
}
#endif
