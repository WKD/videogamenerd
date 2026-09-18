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
                            onShiftTap: { vm.extendSelection(to: game.id); gridFocused = true },
                            onDropCover: { url in vm.importCover(gameID: game.id, from: url) }
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
            .onChange(of: vm.gridFocusRequests) { _, _ in
                gridFocused = true
                if let id = vm.selectedGameIDs.first { proxy.scrollTo(id, anchor: .center) }
            }
            .onKeyPress(action: { handleKeyPress($0, proxy: proxy) })
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ id: Int64?) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
    }

    /// One handler for the grid: arrows (⇧ extends the selection), ↩/space open the
    /// inspector, ⌫ deletes the selection, ⌘A selects all, and any printable
    /// character routes to type-to-select vs the tier/ownership keys.
    private func handleKeyPress(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow:
            scroll(proxy, shift ? vm.extendSelection(by: -1) : vm.moveSelection(by: -1)); return .handled
        case .rightArrow:
            scroll(proxy, shift ? vm.extendSelection(by: 1) : vm.moveSelection(by: 1)); return .handled
        case .upArrow:
            scroll(proxy, shift ? vm.extendSelection(by: -columnCount) : vm.moveSelection(by: -columnCount)); return .handled
        case .downArrow:
            scroll(proxy, shift ? vm.extendSelection(by: columnCount) : vm.moveSelection(by: columnCount)); return .handled
        case .return:
            vm.showInspector(); return .handled
        case .space:
            vm.showInspector(); return .handled
        case .delete:
            guard !vm.selectedGameIDs.isEmpty else { return .ignored }
            vm.actions?.requestDelete(ids: vm.selectedGameIDs); return .handled
        default:
            break
        }
        if press.modifiers.contains(.command) {
            if press.characters.lowercased() == "a" { vm.selectAll(); return .handled }
            return .ignored
        }
        guard let ch = press.characters.first, ch.isLetter || ch.isNumber else { return .ignored }
        if let scrollID = vm.handleGridCharacter(ch) { scroll(proxy, scrollID) }
        return .handled
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
        let query = vm.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentUnavailableView {
            Label("No matches", systemImage: "magnifyingglass")
        } description: {
            Text(vm.filter.hasActiveFacets
                 ? "No games match the current search and filters."
                 : "Nothing in this list yet.")
        } actions: {
            VStack(spacing: 8) {
                if !query.isEmpty {
                    Button {
                        vm.requestQuickAdd(prefill: query)
                    } label: {
                        Label("Add “\(query)” with Quick Add (⌘N)", systemImage: "plus")
                    }
                }
                // One-click escape from a scoped search to the whole library.
                if vm.selection != .all, !query.isEmpty {
                    Button("Search all games") { vm.searchAllScope() }
                }
                if vm.filter.hasActiveFacets {
                    Button("Clear filters") { vm.clearAllFilters() }
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
