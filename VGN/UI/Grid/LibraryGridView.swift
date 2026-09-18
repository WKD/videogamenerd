import SwiftUI

/// The main library grid (PLAN §8): a `LazyVGrid` of fixed-size cells with
/// adaptive columns driven by the toolbar size slider, full click / ⌘-click /
/// ⇧-click / arrow-key selection, a context-menu skeleton and empty states.
struct LibraryGridView: View {
    @Bindable var vm: LibraryViewModel
    @State private var containerWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool

    private let spacing: CGFloat = 14
    private let outerPadding: CGFloat = 16

    private var columnCount: Int {
        let available = containerWidth - outerPadding * 2
        guard available > 0 else { return 1 }
        return max(1, Int((available + spacing) / (CGFloat(vm.gridCellWidth) + spacing)))
    }

    var body: some View {
        Group {
            if vm.isEmptyLibrary {
                emptyLibraryState
            } else if vm.isEmptyFilterResult {
                emptyResultState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widthReader)
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { containerWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, new in containerWidth = new }
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: vm.gridCellWidth,
                                                 maximum: vm.gridCellWidth + 40),
                                       spacing: spacing)],
                    spacing: spacing
                ) {
                    ForEach(vm.games) { game in
                        GameCell(
                            model: vm.cellModel(for: game.id),
                            coverLoader: vm.coverLoader,
                            isSelected: vm.selectedGameIDs.contains(game.id),
                            cellWidth: CGFloat(vm.gridCellWidth),
                            onTap: { vm.selectOnly(game.id); gridFocused = true },
                            onCommandTap: { vm.toggle(game.id); gridFocused = true },
                            onShiftTap: { vm.extendSelection(to: game.id); gridFocused = true }
                        )
                        .id(game.id)
                        .contextMenu { contextMenu(for: game) }
                    }
                }
                .padding(outerPadding)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onAppear { gridFocused = true }
            .onKeyPress(.leftArrow) { scroll(proxy, vm.moveSelection(by: -1)); return .handled }
            .onKeyPress(.rightArrow) { scroll(proxy, vm.moveSelection(by: 1)); return .handled }
            .onKeyPress(.upArrow) { scroll(proxy, vm.moveSelection(by: -columnCount)); return .handled }
            .onKeyPress(.downArrow) { scroll(proxy, vm.moveSelection(by: columnCount)); return .handled }
            .onKeyPress(.return) { vm.showInspector(); return .handled }
            .onKeyPress(.space) { vm.showInspector(); return .handled }
            .onKeyPress(.delete) {
                guard !vm.selectedGameIDs.isEmpty else { return .ignored }
                vm.actions?.requestDelete(ids: vm.selectedGameIDs)
                return .handled
            }
            .onKeyPress(action: handleCharacter)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ id: Int64?) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
    }

    private func handleCharacter(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            if press.characters.lowercased() == "a" { vm.selectAll(); return .handled }
            return .ignored
        }
        guard let ch = press.characters.first, let key = LibraryKey(character: ch) else {
            return .ignored
        }
        return vm.handleKey(key) ? .handled : .ignored
    }

    // MARK: Context menu skeleton (closures wired next wave)

    @ViewBuilder
    private func contextMenu(for game: GameSummary) -> some View {
        let ids = targetIDs(for: game)
        Menu("Set Tier") {
            ForEach(["S", "A", "B", "C", "D", "F"], id: \.self) { letter in
                Button(letter) { vm.setTier(letter, for: ids) }
            }
            Divider()
            Button("Clear") { vm.setTier(nil, for: ids) }
        }
        Button("Mark Played") { vm.setPlayed(true, for: ids) }
        Button("Mark Owned") { vm.setOwned(true, for: ids) }
        Divider()
        Button("Show Inspector") {
            if !vm.selectedGameIDs.contains(game.id) { vm.selectOnly(game.id) }
            vm.showInspector()
        }
        Divider()
        Button("Delete…", role: .destructive) { vm.actions?.requestDelete(ids: ids) }
    }

    /// Act on the whole selection when the right-clicked game is part of it,
    /// otherwise just that game (and make it the selection).
    private func targetIDs(for game: GameSummary) -> Set<Int64> {
        if vm.selectedGameIDs.contains(game.id) { return vm.selectedGameIDs }
        vm.selectOnly(game.id)
        return [game.id]
    }

    // MARK: Empty states

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("No games yet", systemImage: "gamecontroller")
        } description: {
            Text("Press ⌘N to add your first game.")
        }
    }

    private var emptyResultState: some View {
        ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text(vm.filter.hasActiveFacets
                 ? "No games match the current search and filters."
                 : "Nothing in this list yet.")
        } actions: {
            if vm.filter.hasActiveFacets {
                Button("Clear filters") {
                    vm.setFilter(LibraryFilter(scope: vm.selection))
                }
            }
        }
    }
}

#if DEBUG
#Preview("Grid — samples") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    LibraryGridView(vm: vm)
        .task { vm.start() }
        .frame(width: 640, height: 480)
}

#Preview("Grid — large") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.large)
    LibraryGridView(vm: vm)
        .task { vm.start() }
        .frame(width: 760, height: 560)
}

#Preview("Grid — empty") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
    LibraryGridView(vm: vm)
        .task { vm.start() }
        .frame(width: 640, height: 480)
}
#endif
