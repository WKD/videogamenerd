import SwiftUI

/// The main library grid (PLAN §8): a `LazyVGrid` of fixed-size cells with
/// adaptive columns driven by the toolbar size slider, full click / ⌘-click /
/// ⇧-click / arrow-key selection, a context-menu skeleton and empty states.
struct LibraryGridView: View {
    @Bindable var vm: LibraryViewModel
    @State private var containerWidth: CGFloat = 0
    @FocusState private var gridFocused: Bool
    // Read for wiring the empty states to existing commands (no new navigation plumbing).
    @Environment(\.rankingActions) private var rankingActions
    @Environment(\.hltbFetchPresenter) private var hltbPresenter

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
        // The target games' already-loaded summaries, so each submenu shows the current
        // state as ✓ (all) / – (mixed) / nothing (none) without a DB read (PLAN §8, wave 17).
        let targets = vm.games(for: ids)
        Menu("Set Tier") {
            ForEach(["S", "A", "B", "C", "D", "F"], id: \.self) { letter in
                StateMenuButton(title: letter, state: targets.tierState(letter: letter)) {
                    act(on: game) { vm.setTier(letter, for: $0) }
                }
            }
            Divider()
            StateMenuButton(title: "Clear", state: targets.clearTierState) {
                act(on: game) { vm.setTier(nil, for: $0) }
            }
        }
        // Mark Played As (PLAN §8, owner request). The top-level item repeats the
        // last-chosen value; ⇧M is shown as a title hint only — NOT a menu key
        // equivalent, which (shift-only) would steal a capital "M" typed in the
        // search field / Quick Add. The key itself is handled by the grid router.
        let lastMark = vm.lastPlayedMark
        StateMenuButton(title: "\(lastMark.menuTitle)   ⇧M", state: targets.playedMarkState(lastMark)) {
            act(on: game) { vm.markPlayed($0, as: lastMark) }
        }
        Menu("Mark Played As") {
            ForEach(PlayedMark.allCases) { mark in
                StateMenuButton(title: mark.label, state: targets.playedMarkState(mark)) {
                    act(on: game) { vm.markPlayed($0, as: mark) }
                }
            }
        }
        StateMenuButton(title: "Mark Owned", state: targets.ownedState) {
            act(on: game) { vm.setOwned(true, for: $0) }
        }
        // Change the ownership format of the selection's single-copy games (PLAN §13.3).
        // Ticks the current format(s); a mixed set shows "–"; multi-copy games are ignored
        // for the state and called out in a disabled footer.
        Menu("Change Copy Format") {
            ForEach(ProductFormat.allCases, id: \.self) { format in
                StateMenuButton(title: format.label, state: targets.copyFormatState(format)) {
                    act(on: game) { vm.changeCopyFormat($0, to: format) }
                }
            }
            let several = targets.severalCopiesCount
            if several > 0 {
                Divider()
                Button { } label: { Text("^[\(several) game](inflect: true) with several copies not changed") }
                    .disabled(true)
            }
        }
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
        // Reconcile with IGDB — single target only (PLAN §5.1). PURE: the label reads
        // the single-selection detail when available, else defaults to "Link…"; the
        // sheet adapts its own title. Selection/state changes happen in the action.
        if ids.count == 1 {
            Button(linkMenuLabel(for: game)) { act(on: game) { _ in vm.requestLinkToIGDB(gameID: game.id) } }
            // "Expand Bundle into Games…" (PLAN §5.1 repair path): the on-demand IGDB check +
            // confirm runs in the presenter. Offered here so the "Bundles to Expand" smart list
            // and any single selection can expand from the grid, matching the inspector / File menu.
            Button("Expand Bundle into Games…") { act(on: game) { _ in vm.requestExpandBundle(gameID: game.id) } }
        }
        // Cover is per-game: only offered for a single target (not a multi-selection),
        // and only when the loader can browse candidates. PURE — reads only.
        if ids.count == 1, vm.canChooseCover {
            Button("Choose Cover…") { vm.requestChooseCover(gameID: game.id) }
        }
        Button("Show Inspector") {
            if !vm.selectedGameIDs.contains(game.id) { vm.selectOnly(game.id) }
            vm.showInspector()
        }
        // Replace-from-HowLongToBeat on the selection (PLAN §5.3): unlike the gap-fill,
        // this overwrites the three estimates for the flagged games. Confirms first.
        if let hltb = hltbPresenter, hltb.canRunBulk {
            Divider()
            Button("Refresh Time Estimates from HowLongToBeat…") {
                act(on: game) { _ in hltb.presentRefresh() }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { act(on: game) { vm.actions?.requestDelete(ids: $0) } }
    }

    /// The reconcile menu label. PURE: uses the single-selection live detail when the
    /// right-clicked game is that game (so a linked game reads "Change IGDB Match…"),
    /// otherwise defaults to "Link to IGDB…" (the sheet adapts either way).
    private func linkMenuLabel(for game: GameSummary) -> String {
        if vm.selectedGameIDs.count == 1, vm.selectedGameIDs.first == game.id,
           let detail = vm.selectedDetail, detail.id == game.id {
            return detail.igdbID == nil ? "Link to IGDB…" : "Change IGDB Match…"
        }
        return "Link to IGDB…"
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
        EmptyStateView(
            systemImage: "gamecontroller",
            title: "No games yet",
            message: "Add the games you own or have played, then rank the ones worth ranking.",
            actions: [
                EmptyStateAction(title: "Quick Add", systemImage: "plus", isProminent: true,
                                 accessibilityID: "grid.empty.quickAdd") { vm.requestQuickAdd() },
            ],
            accessibilityID: "grid.empty.library")
    }

    @ViewBuilder
    private var emptyResultState: some View {
        let query = vm.filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if vm.filter.hasActiveFacets || !query.isEmpty {
            EmptyStateView(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: query.isEmpty
                    ? "No games match the current filters."
                    : "No games match “\(query)”.",
                actions: noMatchActions(query: query),
                accessibilityID: "grid.empty.noMatches")
        } else {
            let e = Self.smartListEmpty(for: vm.selection)
            EmptyStateView(systemImage: e.symbol, title: e.title, message: e.message,
                           actions: smartListActions(e.action),
                           accessibilityID: "grid.empty.list")
        }
    }

    /// Up to two escapes from a fruitless search/filter, wired to the existing clears.
    private func noMatchActions(query: String) -> [EmptyStateAction] {
        var actions: [EmptyStateAction] = []
        let scoped = vm.selection != .all && !query.isEmpty
        if scoped {
            actions.append(EmptyStateAction(title: "Search all games", isProminent: true) {
                vm.searchAllScope()
            })
        }
        if vm.filter.hasActiveFacets {
            actions.append(EmptyStateAction(title: "Clear filters", isProminent: !scoped,
                                            accessibilityID: "grid.empty.clearFilters") {
                vm.clearAllFilters()
            })
        } else if !query.isEmpty {
            actions.append(EmptyStateAction(title: "Clear search", isProminent: !scoped,
                                            accessibilityID: "grid.empty.clearFilters") {
                _ = vm.clearSearch()
            })
        }
        if actions.count < 2, !query.isEmpty {
            actions.append(EmptyStateAction(title: "Add “\(query)”", systemImage: "plus") {
                vm.requestQuickAdd(prefill: query)
            })
        }
        return actions
    }

    /// Which empty-state action a smart list wants (resolved to a real callback here, where the
    /// environment presenters are in scope). Internal so the pure mapping is unit-tested.
    enum SmartListAction { case quickAdd, startRanking, fetchTimes, none }

    private func smartListActions(_ kind: SmartListAction) -> [EmptyStateAction] {
        switch kind {
        case .quickAdd:
            return [EmptyStateAction(title: "Quick Add", systemImage: "plus", isProminent: true,
                                     accessibilityID: "grid.empty.quickAdd") { vm.requestQuickAdd() }]
        case .startRanking:
            guard let goToDuel = rankingActions.goToDuel else { return [] }
            return [EmptyStateAction(title: "Start ranking", systemImage: "square.stack.3d.up.fill",
                                     isProminent: true) { goToDuel() }]
        case .fetchTimes:
            guard let hltb = hltbPresenter, hltb.canRunBulk else { return [] }
            return [EmptyStateAction(title: "Fetch Missing Time Estimates…",
                                     systemImage: "clock.arrow.circlepath") { hltb.presentBulk() }]
        case .none:
            return []
        }
    }

    /// Per-selection copy for an empty smart list (no active search/filter). Second person,
    /// concrete, no exclamation marks.
    static func smartListEmpty(for selection: SidebarSelection)
        -> (symbol: String, title: String, message: String, action: SmartListAction) {
        switch selection {
        case .backlog:
            return ("tray", "Your backlog is empty",
                    "Games you own but haven't played show up here. Mark a game as owned to build a backlog.",
                    .quickAdd)
        case .unranked:
            return ("questionmark.square.dashed", "Nothing left to rank",
                    "Every played game sits in a tier. Mark more games as played, or start ranking to place them.",
                    .startRanking)
        case .unlinked:
            return ("link", "Everything is linked",
                    "Every game is matched to IGDB, so metadata, covers and time estimates can be fetched.",
                    .none)
        case .owned:
            return ("shippingbox", "Nothing owned yet",
                    "Add the games you own — physical, digital or ROM — and they'll appear here.",
                    .quickAdd)
        case .played:
            return ("gamecontroller", "Nothing played yet",
                    "Mark the games you've played and they'll gather here, ready to rank.",
                    .quickAdd)
        case .unmeasured:
            return ("clock.badge.questionmark", "No unmeasured games",
                    "Every game has a completion-time estimate. Fetch missing estimates when new games arrive.",
                    .fetchTimes)
        case .length:
            return ("clock", "Nothing on this shelf",
                    "No games fall in this length range yet. Fetch missing time estimates to sort more games onto the length shelves.",
                    .fetchTimes)
        case .platform(let slug):
            return ("square.grid.2x2", "No \(PlatformLabels.short(slug)) games",
                    "Add a game on this platform and it'll appear here.", .quickAdd)
        default:
            return ("tray", "Nothing here yet", "This list has no games yet.", .quickAdd)
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
