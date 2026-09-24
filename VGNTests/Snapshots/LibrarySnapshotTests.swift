#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The main window (PLAN §8): the three panes composed by hand (see
/// `SnapSupport.mainWindow` / `docs/snapshots.md` for why `NavigationSplitView`
/// and the live `LibraryGridView` `ScrollView` can't render headless), the grid
/// content, sidebar, filter chips, cells and empty states.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
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

    /// Three wrapped chip rows; the "N of M games" count pinned trailing on the FIRST row.
    @Test func filterChips() async {
        var f = LibraryFilter(scope: .all)
        f.searchText = "souls"
        f.genres = ["RPG", "Adventure"]
        f.tierIDs = [1, 2]
        f.formats = [.rom, .physical]
        f.platforms = ["ps4", "snes"]
        let vm = await SnapSupport.libraryVM(.sampled, filter: f)
        await SnapshotHarness.capture(group: group, "library-filter-chips",
                                      size: SnapSize(width: 500, height: 120), settle: 4) {
            FilterChipsBar(vm: vm).frame(width: 480).padding(8)
        }
    }

    /// One chip row; the count at the trailing edge, on the chips' baseline.
    @Test func filterChipsOneRow() async {
        var f = LibraryFilter(scope: .all)
        f.genres = ["RPG"]
        f.tierIDs = [1]
        let vm = await SnapSupport.libraryVM(.sampled, filter: f)
        await SnapshotHarness.capture(group: group, "library-filter-chips-one-row",
                                      size: SnapSize(width: 660, height: 60), settle: 4) {
            FilterChipsBar(vm: vm).frame(width: 640).padding(8)
        }
    }

    // MARK: Seeded sidebar (THE VAULT · Unlinked · Bundles to Expand · BY LENGTH pace-only)

    /// A forwarding data source that carries the sidebar/vault counts a plain
    /// `PreviewLibraryDataSource` hard-codes to zero, so the conditional sections render.
    private struct SeededSidebarSource: LibraryDataSource {
        var base: PreviewLibraryDataSource
        var counts: SidebarCounts
        var vault: VaultSourceCounts
        func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> { onceStream(counts) }
        func vaultSourceCounts() -> AsyncStream<VaultSourceCounts> { onceStream(vault) }
        func platformsInUse() -> AsyncStream<[PlatformInfo]> { base.platformsInUse() }
        func tiers() -> AsyncStream<[TierInfo]> { base.tiers() }
        func genresInUse() -> AsyncStream<[String]> { base.genresInUse() }
        func decadesInUse() -> AsyncStream<[Int]> { base.decadesInUse() }
        func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> { base.games(filter: filter) }
        func gameDetail(id: Int64) async -> GameDetail? { await base.gameDetail(id: id) }
        func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> { base.gameDetailStream(id: id) }
    }

    @Test func sidebarSeeded() async {
        let counts = SidebarCounts(
            all: 400, owned: 320, played: 300, backlog: 20, unranked: 40, duelQueue: 12,
            perPlatform: [:],
            lengthShelves: [.evening: 30, .weekend: 55, .fewWeeks: 40, .season: 22, .epic: 8],
            unmeasured: 14, unlinked: 7, bundlesToExpand: 3)
        let vault = VaultSourceCounts(batocera: 11834, psn: 42, gog: 18, delicious: 25)
        let source = SeededSidebarSource(base: SnapSupport.bigLibrarySource(400),
                                         counts: counts, vault: vault)
        let vm = LibraryViewModel(dataSource: source)
        vm.start()
        await SnapshotHarness.settle(rounds: 8)
        await SnapshotHarness.capture(group: group, "library-sidebar-seeded",
                                      size: SnapSize(width: 260, height: 760)) {
            SidebarView(vm: vm).frame(width: 240)
        }
    }

    // MARK: Grid tile format badges

    @Test func cellBadgeStates() async {
        let variants: [GameSummary] = [
            GameSummary(id: 101, title: "Physical", year: 2015, tierLetter: "S", tierColorHex: "#FF7F7F",
                        played: true, owned: true, platformIDs: ["ps4"],
                        physicalPlatformIDs: ["ps4"], singleCopyFormat: .physical),
            GameSummary(id: 102, title: "Digital", year: 2022, played: true, owned: true,
                        platformIDs: ["ps5"], digitalPlatformIDs: ["ps5"], singleCopyFormat: .digital),
            GameSummary(id: 103, title: "ROM", year: 1998, played: true, owned: true,
                        platformIDs: ["snes"], hasROM: true, romPlatformIDs: ["snes"]),
            GameSummary(id: 104, title: "PS Plus only", year: 2020, played: false, owned: true,
                        platformIDs: ["ps5"], ownedOnlyViaSubscription: true, subscriptionPlatformIDs: ["ps5"]),
            GameSummary(id: 105, title: "Physical + ROM", year: 2004, played: true, owned: true,
                        platformIDs: ["ps2"], hasROM: true, physicalPlatformIDs: ["ps2"], romPlatformIDs: ["ps2"]),
            GameSummary(id: 106, title: "Digital + PS Plus", year: 2022, played: true, owned: true,
                        platformIDs: ["ps5", "ps4"], digitalPlatformIDs: ["ps5"], subscriptionPlatformIDs: ["ps4"]),
            GameSummary(id: 107, title: "Played, not owned", year: 1996, played: true, owned: false,
                        platformIDs: ["pc"]),
            GameSummary(id: 108, title: "Not owned", year: 2025, played: false, owned: false,
                        platformIDs: ["pc"]),
            // The worst case: physical + digital + ROM + PS Plus + played = 5 badges.
            GameSummary(id: 109, title: "Everything", year: 2013, played: true, owned: true,
                        platformIDs: ["ps3"], hasROM: true,
                        physicalPlatformIDs: ["ps3"], digitalPlatformIDs: ["ps3"],
                        romPlatformIDs: ["ps3"], subscriptionPlatformIDs: ["ps3"]),
        ]
        await SnapshotHarness.capture(group: group, "library-cell-badges",
                                      size: SnapSize(width: 700, height: 480), settle: 4) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180))], spacing: 14) {
                ForEach(variants) { g in
                    GameCell(model: GameCellModel(summary: g), coverLoader: NoopCoverLoader())
                }
            }
            .padding()
            .frame(width: 660)
        }
    }

    /// The five-badge worst case at the smallest tile (110 pt): the badge row wraps to a second
    /// line rather than overflow the tile (wave 19, D1/D4).
    @Test func cellBadgeStatesMinTile() async {
        let everything = GameSummary(id: 110, title: "Everything Small", year: 2013,
                                     played: true, owned: true, platformIDs: ["ps3"], hasROM: true,
                                     physicalPlatformIDs: ["ps3"], digitalPlatformIDs: ["ps3"],
                                     romPlatformIDs: ["ps3"], subscriptionPlatformIDs: ["ps3"])
        await SnapshotHarness.capture(group: group, "library-cell-badges-min",
                                      size: SnapSize(width: 300, height: 230), settle: 4) {
            HStack(spacing: 14) {
                GameCell(model: GameCellModel(summary: everything),
                         coverLoader: NoopCoverLoader(), cellWidth: 110)
                    .frame(width: 110)
                GameCell(model: GameCellModel(summary: everything),
                         coverLoader: NoopCoverLoader(), cellWidth: 150)
                    .frame(width: 150)
            }
            .padding()
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
