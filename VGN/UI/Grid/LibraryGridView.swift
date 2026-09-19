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
                            score: vm.scoresByGameID[game.id],
                            cellWidth: CGFloat(vm.gridCellWidth),
                            onTap: { vm.selectOnly(game.id); gridFocused = true },
                            onCommandTap: { vm.toggle(game.id); gridFocused = true },
                            onShiftTap: { vm.extendSelection(to: game.id); gridFocused = true },
                            onDropCover: { url in vm.importCover(gameID: game.id, from: url) }
                        )
                        .id(game.id)
                        .accessibilityIdentifier(A11yID.gridCell(game.id))
                        .contextMenu { contextMenu(for: game) }
                    }
                }
                .padding(outerPadding)
            }
            .accessibilityIdentifier(A11yID.grid)
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
    /// character routes through ``GridKeyRouter`` — plain letters type-to-select,
    /// `⇧S…⇧F`/`⇧O`/`⇧P` act, plain `0` clears the tier.
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
        guard let action = GridKeyRouter.route(characters: press.characters,
                                               modifiers: press.modifiers) else {
            return .ignored
        }
        if let scrollID = vm.applyGridAction(action) { scroll(proxy, scrollID) }
        return .handled
    }

    // MARK: Context menu skeleton (closures wired next wave)

    @ViewBuilder
    private func contextMenu(for game: GameSummary) -> some View {
        // NOTE: this builder runs during view updates (SwiftUI builds every cell's
        // menu eagerly), so it must be PURE. Mutating the selection here caused an
        // endless invalidate → rebuild loop (100 % CPU). Selection changes happen
        // only inside the action closures, via `act(on:)`.
        let ids = targetIDs(for: game)
        Menu("Set Tier") {
            ForEach(["S", "A", "B", "C", "D", "F"], id: \.self) { letter in
                Button(letter) { act(on: game) { vm.setTier(letter, for: $0) } }
            }
            Divider()
            Button("Clear") { act(on: game) { vm.setTier(nil, for: $0) } }
        }
        Button("Mark Played") { act(on: game) { vm.setPlayed(true, for: $0) } }
        Button("Mark Owned") { act(on: game) { vm.setOwned(true, for: $0) } }
        Divider()
        // Compilations (PLAN §8).
        if game.isCompilationMember, let productID = game.compilationProductID {
            Button("Show Compilation") { vm.showCompilation(productID: productID) }
            Button("Edit Compilation…") { vm.editCompilation(productID: productID) }
        }
        if ids.count > 1 {
            Button("Group as Compilation…") { act(on: game) { vm.onGroupAsCompilation($0) } }
        }
        Divider()
        Button("Show Inspector") {
            if !vm.selectedGameIDs.contains(game.id) { vm.selectOnly(game.id) }
            vm.showInspector()
        }
        Divider()
        Button("Delete…", role: .destructive) { act(on: game) { vm.actions?.requestDelete(ids: $0) } }
    }

    /// The games a context-menu action applies to: the whole selection when the
    /// right-clicked game is part of it, otherwise just that game. PURE — it is
    /// called while the menu is being built (i.e. during view updates).
    private func targetIDs(for game: GameSummary) -> Set<Int64> {
        vm.selectedGameIDs.contains(game.id) ? vm.selectedGameIDs : [game.id]
    }

    /// Runs a context-menu action: resolves the targets at click time and, Finder-style,
    /// makes the right-clicked game the selection when it was not part of it.
    private func act(on game: GameSummary, _ action: (Set<Int64>) -> Void) {
        let ids = targetIDs(for: game)
        if !vm.selectedGameIDs.contains(game.id) { vm.selectOnly(game.id) }
        action(ids)
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
