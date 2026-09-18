#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import VGN

// Shared builders for the snapshot suites: they construct a view model / model,
// drive it to its loaded state, and settle the run loop, so captures reflect the
// real populated UI instead of a first-frame loading state.

@MainActor
enum SnapSupport {

    /// A started + settled `LibraryViewModel` over a preview data source.
    static func libraryVM(
        _ source: PreviewLibraryDataSource,
        selection: SidebarSelection? = nil,
        selected: Set<Int64> = [],
        filter: LibraryFilter? = nil,
        inspector: Bool = false
    ) async -> LibraryViewModel {
        let vm = LibraryViewModel(dataSource: source)
        vm.start()
        await SnapshotHarness.settle(rounds: 8)
        if let selection { vm.select(selection) }
        if let filter { vm.setFilter(filter) }
        if !selected.isEmpty { vm.selectedGameIDs = selected }
        vm.inspectorPresented = inspector
        await SnapshotHarness.settle(rounds: 6)
        return vm
    }

    /// A synthetic library of `n` games with covers absent (placeholder art),
    /// varied tiers/platforms/titles — for grid density / performance eyeballing.
    static func bigLibrarySource(_ n: Int) -> PreviewLibraryDataSource {
        let platforms = ["ps5", "ps4", "ps2", "ps3", "switch", "snes", "pc", "xbox360", "gamecube", "genesis"]
        let tiers = TierInfo.defaultTiers
        var games: [GameSummary] = []
        games.reserveCapacity(n)
        for i in 0..<n {
            let played = i % 4 != 0
            let hasTier = played && i % 3 != 0
            let tier = tiers[i % tiers.count]
            games.append(GameSummary(
                id: Int64(1000 + i),
                title: "Sample Game \(i + 1)\(i % 9 == 0 ? ": A Rather Long Subtitle" : "")",
                year: 1985 + (i % 40),
                tierID: hasTier ? tier.id : nil,
                tierLetter: hasTier ? tier.letter : nil,
                tierColorHex: hasTier ? tier.colorHex : nil,
                rankKey: hasTier ? RankKey(i * 100) : nil,
                played: played,
                owned: i % 5 != 0,
                isCompilationMember: i % 13 == 0,
                platformIDs: [platforms[i % platforms.count]],
                status: played ? PlayStatus.allCases[i % PlayStatus.allCases.count] : nil,
                hasROM: i % 17 == 0))
        }
        return PreviewLibraryDataSource(games: games)
    }

    /// Wrap a sidebar/detail pair in a `NavigationSplitView` so List-backed
    /// sidebars render as the real three-pane shell would.
    static func split(@ViewBuilder _ sidebar: () -> some View,
                      @ViewBuilder detail: () -> some View) -> some View {
        NavigationSplitView { sidebar() } detail: { detail() }
    }

    /// The main window as a snapshot renders it: the same three panes as
    /// `RootView` (sidebar · filter chips + grid · inspector), composed by hand.
    ///
    /// Two headless-rendering constraints shape this (both documented in
    /// `docs/snapshots.md`, both covered live by the XCUITest suite):
    /// * `NavigationSplitView` is replaced by a plain `HStack` + `Divider`s — the
    ///   split controller trips an AttributeGraph precondition in a scene-less
    ///   window.
    /// * `LibraryGridView`'s `ScrollView` + `.focused`/`.onKeyPress` loops forever
    ///   off-screen, so the grid *content* (the very same `GameCell`s in the very
    ///   same `LazyVGrid`) is rendered directly, clipped to the pane like a real
    ///   viewport. The toolbar (titlebar-only) is absent.
    @ViewBuilder
    static func mainWindow(vm: LibraryViewModel, inspector: Bool = false, cellLimit: Int? = nil) -> some View {
        HStack(spacing: 0) {
            SidebarView(vm: vm)
                .frame(width: 240)
            Divider()
            VStack(spacing: 0) {
                if !vm.isRankingSelection && !vm.isPlayNextSelection {
                    FilterChipsBar(vm: vm)
                    Divider()
                }
                GridContent(vm: vm, limit: cellLimit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if inspector {
                Divider()
                InspectorView(vm: vm).frame(width: 300)
            }
        }
    }
}

/// The library grid's *content* without its `ScrollView`/focus/key handling — a
/// `LazyVGrid` of the real `GameCell`s, clipped to the pane so it reads like a
/// viewport. Used only by the snapshot harness (`LibraryGridView` itself loops in
/// a headless window). Mirrors `LibraryGridView`'s empty states.
@MainActor
struct GridContent: View {
    let vm: LibraryViewModel
    var limit: Int?

    private var games: [GameSummary] {
        guard let limit else { return vm.games }
        return Array(vm.games.prefix(limit))
    }

    var body: some View {
        Group {
            if vm.isEmptyLibrary {
                ContentUnavailableView("No games yet", systemImage: "gamecontroller",
                                       description: Text("Press ⌘N to add your first game."))
            } else if vm.isEmptyFilterResult {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                       description: Text("No games match the current filters."))
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: CGFloat(vm.gridCellWidth),
                                                 maximum: CGFloat(vm.gridCellWidth) + 40), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(games) { game in
                        GameCell(model: vm.cellModel(for: game.id),
                                 coverLoader: vm.coverLoader,
                                 isSelected: vm.selectedGameIDs.contains(game.id))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
#endif
