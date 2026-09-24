import SwiftUI

/// The main window shell (PLAN §8): a plain `NavigationSplitView` (sidebar |
/// content) with a trailing `.inspector`. Not an AppKit split shell — PLAN §3
/// "Done differently".
struct RootView: View {
    @Bindable var vm: LibraryViewModel
    /// The Quick Add palette (PLAN §6.1); nil in previews.
    var quickAdd: QuickAddModel?
    var quickAddController: QuickAddPanelController?
    var enrichment: EnrichmentStatusModel?
    @FocusState private var searchFocused: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, enrichment: enrichment)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            content
                .navigationTitle(SidebarView.title(for: vm.selection))
                .inspector(isPresented: $vm.inspectorPresented) {
                    InspectorView(vm: vm)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
                }
                .toolbar { toolbarContent }
        }
        // Live tier labels for every `TierChip` tooltip (hover a letter → "S — Masterpiece").
        .environment(\.tierLabels, Dictionary(
            vm.tiers.map { ($0.letter.uppercased(), $0.label) }, uniquingKeysWith: { first, _ in first }))
        .task { vm.start() }
        .task { enrichment?.start() }
        .onAppear { vm.undoManager = undoManager }
        .onChange(of: vm.searchFocusRequests) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in vm.searchFieldFocused = focused }
        .onChange(of: vm.quickAddPresented) { _, presented in
            if presented { presentQuickAdd() } else { quickAddController?.hide() }
        }
        .sheet(item: $vm.ownershipRequest) { request in
            OwnershipPickerSheet(request: request) { vm.ownershipRequest = nil }
        }
        .sheet(item: $vm.batchOwnershipRequest) { model in
            BatchOwnershipSheet(model: model) { vm.batchOwnershipRequest = nil }
        }
        .sheet(item: $vm.copyRemovalRequest) { request in
            CopyRemovalSheet(request: request) { vm.copyRemovalRequest = nil }
        }
        .sheet(item: $vm.groupCompilationRequest) { request in
            GroupCompilationSheet(request: request) { vm.groupCompilationRequest = nil }
        }
        .sheet(isPresented: compilationEditorPresented) {
            if let editor = vm.compilationEditor {
                CompilationEditorView(model: editor, loader: vm.coverLoader)
            }
        }
        // "Choose Cover…" (PLAN §5.2 step 4) — shared by the inspector button and the
        // grid context menu via `vm.chooseCoverRequest`.
        .sheet(item: $vm.chooseCoverRequest) { model in
            ChooseCoverSheet(model: model, loader: vm.coverLoader)
        }
        .alert(
            vm.pendingConfirmation?.title ?? "",
            isPresented: confirmationPresented,
            presenting: vm.pendingConfirmation
        ) { confirmation in
            Button(confirmation.confirmTitle,
                   role: confirmation.isDestructive ? .destructive : nil) {
                confirmation.perform()
                vm.pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { vm.pendingConfirmation = nil }
        } message: { confirmation in
            Text(confirmation.message)
        }
        // Expose the view model to the scene's Commands (⌘I / ⌘F / View menu).
        .focusedSceneValue(\.library, vm)
        // On-demand UI smoke suite: `-VGNDisableAnimations YES` steadies focus /
        // label assertions by suppressing implicit animations (harmless in the app;
        // the flag is only ever passed by the test runner).
        .transaction { txn in
            if RootView.animationsDisabled { txn.disablesAnimations = true }
        }
    }

    /// Honours the `-VGNDisableAnimations` launch hook (UI smoke suite only).
    static var animationsDisabled: Bool {
        UserDefaults.standard.bool(forKey: "VGNDisableAnimations")
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if vm.showsGridToolbar {
                FilterChipsBar(vm: vm)
            }
            // The "Bundles to Expand" explanation is a slim bar mounted in this outer
            // VStack — like `FilterChipsBar` — NOT wrapped in an inner `VStack { header;
            // grid }` inside the ZStack below. Wrapping the grid that way stopped the grid's
            // ScrollView from being the detail column's top scroll view, so the unified
            // toolbar lost its scroll tracking and the WHOLE window (sidebar included) lost
            // its top title-bar inset — rows drew under the traffic lights and the sidebar
            // could not be scrolled back up (owner bug, wave 17). Keeping the grid as the
            // ZStack's direct child in every scope fixes it.
            if vm.isBundlesToExpandSelection {
                BundlesToExpandHeader(vm: vm)
            }
            // "Needs a 'Holds Up' Rating" (PLAN §7b) — same slim, bounded bar, mounted the same
            // way (outer VStack, never wrapping the grid).
            if vm.isNeedsHoldsUpRatingSelection {
                HoldsUpRatingHeader()
            }
            if vm.isPSPlusOnlySelection {
                PSPlusOnlyHeader(count: vm.counts.psPlusOnly)
            }
            // STRUCTURAL GUARD (wave 19): the destination area lives inside a `GeometryReader`
            // so the DETAIL column can never leak an unbounded ideal height into the
            // `NavigationSplitView` — which would size BOTH columns to it and push the sidebar
            // up under the title bar (owner bug, waves 17 + 19). A `GeometryReader` fills the
            // space the fixed-height header bars leave and proposes a CONCRETE size to its child,
            // so even a child with `.fixedSize(vertical: true)` multi-line text can no longer
            // move the sidebar (`.frame(maxHeight:)`/`idealHeight` do NOT contain it — proven in
            // `SidebarJumpMatrixTests`). The grid stays the ZStack's direct child (and the detail
            // column's top scroll view, for the unified toolbar's scroll tracking); the
            // `GeometryReader` is not a scroll view, so it does not disturb that.
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    if vm.isRankingSelection {
                        RankingPlaceholderView(selection: vm.selection)
                            .environment(\.rankingLibraryFilter, vm.filter)
                            .environment(\.rankingActions, RankingViewActions(
                                goToDuel: { vm.select(.duel) },
                                inspect: { id in vm.selectOnly(id); vm.showInspector() }))
                    } else if vm.isPlayNextSelection {
                        PlayNextView()
                            .environment(\.rankingActions, RankingViewActions(
                                goToDuel: { vm.select(.duel) },
                                inspect: { id in vm.selectOnly(id); vm.showInspector() }))
                    } else if vm.isVaultSelection {
                        RomCatalogueView(source: vm.selectedVaultSource ?? .batocera)
                    } else {
                        LibraryGridView(vm: vm)
                    }
                    if let banner = vm.banner {
                        BannerView(banner: banner,
                                   onAction: banner.actionTitle != nil ? { vm.performBannerAction() } : nil,
                                   onSecondaryAction: banner.secondaryActionTitle != nil ? { vm.performBannerSecondaryAction() } : nil,
                                   onDismiss: { vm.dismissBanner() })
                            .padding(12)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(.easeInOut(duration: 0.2), value: vm.banner)
            }
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { vm.pendingConfirmation != nil },
            set: { if !$0 { vm.pendingConfirmation = nil } }
        )
    }

    private var compilationEditorPresented: Binding<Bool> {
        Binding(
            get: { vm.compilationEditor != nil },
            set: { if !$0 { vm.compilationEditor = nil } }
        )
    }

    // MARK: Quick Add (PLAN §6.1)

    /// Prime the palette from the current sidebar scope / library platforms, then
    /// float the panel.
    private func presentQuickAdd() {
        guard let quickAdd, let quickAddController else { return }
        quickAdd.prepare(
            sidebarPlatform: vm.selection.platformSlug,
            ownedPlatforms: Set(vm.platforms.map(\.id)),
            tiers: vm.tiers
        )
        // Prefill from the empty-result "Add … with Quick Add" affordance (PLAN §8).
        if let prefill = vm.consumeQuickAddPrefill() { quickAdd.query = prefill }
        quickAddController.show()
    }

    // MARK: Toolbar (PLAN §8)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The grid controls (search, filters, sort, size) belong only to a library grid
        // destination; a ranking view, Play Next and the Vault browser have their own controls,
        // so showing these there was just dead UI (D1, PLAN §8). Hiding them is toolbar-only —
        // it never changes the sidebar / safe-area geometry.
        if vm.showsGridToolbar {
            ToolbarItemGroup(placement: .principal) {
                LibrarySearchField(
                    text: $vm.searchText,
                    focus: $searchFocused,
                    onClear: { _ = vm.clearSearch(); searchFocused = true },
                    onDownArrow: { vm.focusGridFromSearch() },
                    onEscape: { if !vm.clearSearch() { searchFocused = false } },
                    onSubmit: { vm.openFirstResult() }
                )
                .frame(minWidth: 160, idealWidth: 220)
                .help("Search titles (⌘F). ↓ into results · ↩ open first · esc clear")
            }

            ToolbarItemGroup(placement: .automatic) {
                genreMenu
                decadeMenu
                tierMenu
                statusMenu
                holdsUpMenu
                formatMenu
                playtimeMenu
                platformMenu
                sortMenu

                Slider(value: $vm.gridCellWidth,
                       in: LibraryViewModel.minCellWidth...LibraryViewModel.maxCellWidth)
                    .frame(width: 90)
                    .help("Grid size")
            }
        }

        // The inspector toggle and Quick Add are app-level actions, shown everywhere.
        ToolbarItemGroup(placement: .automatic) {
            Button {
                vm.toggleInspector()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .accessibilityIdentifier(A11yID.toolbarInspector)
            .help("Toggle inspector (⌘I)")

            Button {
                vm.requestQuickAdd()
            } label: {
                Label("Add Game", systemImage: "plus")
            }
            .accessibilityIdentifier(A11yID.toolbarAdd)
            .help("Quick Add (⌘N)")
        }
    }

    // Genres populated live from the DB (in-use only — UIFacets).
    private var genreMenu: some View {
        Menu {
            if vm.genresInUse.isEmpty {
                Button("No genres yet") {}.disabled(true)
            } else {
                ForEach(vm.genresInUse, id: \.self) { genre in
                    Toggle(genre, isOn: membership(\.genres, genre))
                }
                if !vm.filter.genres.isEmpty {
                    Divider()
                    Button("Clear") { clear(\.genres) }
                }
            }
        } label: {
            Label("Genre", systemImage: "theatermasks")
                .symbolVariant(vm.filter.genres.isEmpty ? .none : .fill)
        }
    }

    // Decades populated live from the DB (in-use only — UIFacets).
    private var decadeMenu: some View {
        Menu {
            if vm.decadesInUse.isEmpty {
                Button("No decades yet") {}.disabled(true)
            } else {
                ForEach(vm.decadesInUse, id: \.self) { decade in
                    Toggle("\(decade)s", isOn: membership(\.decades, decade))
                }
                if !vm.filter.decades.isEmpty {
                    Divider()
                    Button("Clear") { clear(\.decades) }
                }
            }
        } label: {
            Label("Decade", systemImage: "calendar")
                .symbolVariant(vm.filter.decades.isEmpty ? .none : .fill)
        }
    }

    private var tierMenu: some View {
        Menu {
            ForEach(vm.tiers) { tier in
                Toggle("\(tier.letter) · \(tier.label)", isOn: membership(\.tierIDs, tier.id))
            }
            Divider()
            Toggle("Unrated", isOn: flag(\.includeUnrated))
            if !vm.filter.tierIDs.isEmpty || vm.filter.includeUnrated {
                Divider()
                Button("Clear") { clearTierFacet() }
            }
        } label: {
            Label("Tier", systemImage: "chart.bar")
                .symbolVariant(vm.filter.tierIDs.isEmpty && !vm.filter.includeUnrated ? .none : .fill)
        }
        .accessibilityIdentifier(A11yID.toolbarFilterTier)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(PlayStatus.allCases) { status in
                Toggle(status.label, isOn: membership(\.statuses, status))
            }
            Divider()
            Toggle("Played, No Status", isOn: flag(\.includeNoStatus))
                .help("Games you've marked played but not given a completion status (photo scans, Quick Add, imports) — how you find games to “Mark Played As”.")
            Toggle("Not Played", isOn: flag(\.includeNotPlayed))
                .help("Games you haven't played (played = off).")
            if statusFacetActive {
                Divider()
                Button("Clear") { clearStatusFacet() }
            }
        } label: {
            Label("Status", systemImage: "flag")
                .symbolVariant(statusFacetActive ? .fill : .none)
        }
        .accessibilityIdentifier(A11yID.toolbarFilterStatus)
    }

    // "Holds up today?" (PLAN §7b/§8): the three marks + Unrated (played, no mark yet).
    private var holdsUpMenu: some View {
        Menu {
            ForEach(HoldsUp.allCases) { value in
                Toggle(value.label, isOn: membership(\.holdsUp, value))
                    .help(value.explanation)
            }
            Divider()
            Toggle(HoldsUp.unratedLabel, isOn: flag(\.includeHoldsUpUnrated))
                .help("Played games you haven't judged yet — the \u{201C}Needs a \u{2018}Holds Up\u{2019} Rating\u{201D} list.")
            if holdsUpFacetActive {
                Divider()
                Button("Clear") { clearHoldsUpFacet() }
            }
        } label: {
            Label("Holds Up", systemImage: "hourglass")
                .symbolVariant(holdsUpFacetActive ? .fill : .none)
        }
        .help("Holds up today? — filter by how a played game plays now")
    }

    private var holdsUpFacetActive: Bool {
        !vm.filter.holdsUp.isEmpty || vm.filter.includeHoldsUpUnrated
    }

    private func clearHoldsUpFacet() {
        var f = vm.filter
        f.holdsUp.removeAll()
        f.includeHoldsUpUnrated = false
        vm.setFilter(f)
    }

    private var statusFacetActive: Bool {
        !vm.filter.statuses.isEmpty || vm.filter.includeNotPlayed || vm.filter.includeNoStatus
    }

    // Ownership format (physical / digital / ROM) + the "Multiple Copies" facet,
    // driven by ProductFormat. "Multiple Copies" (≥ 2 owned products) is its own facet
    // that ANDs with the formats — "Physical" + "Multiple Copies" = games with a
    // physical copy that are owned several times (owner request 2026-09-19: folded in
    // here to save toolbar space).
    private var formatMenu: some View {
        Menu {
            ForEach(ProductFormat.allCases, id: \.self) { format in
                Toggle(format.label, isOn: membership(\.formats, format))
            }
            Divider()
            Toggle("Not Owned", isOn: flag(\.includeNotOwned))
            Toggle("Multiple Copies", isOn: flag(\.multipleCopies))
                .help("Games you own more than once — several copies or formats (e.g. physical + digital). ANDs with a chosen format.")
            Toggle("Duplicate Copies", isOn: flag(\.duplicateCopies))
                .help("Games you own twice on the SAME platform and format — e.g. two physical PS3 discs of one game. ANDs with a chosen format.")
            Toggle("PS Plus", isOn: flag(\.includeSubscriptionOnly))
                .help("Games you own only through PS Plus — at risk when the subscription lapses. With Status ▸ Not Played, your \u{201C}finish before unsubscribing\u{201D} list.")
            if formatFacetActive {
                Divider()
                Button("Clear") { clearFormatFacet() }
            }
        } label: {
            Label("Format", systemImage: "opticaldisc")
                .symbolVariant(formatFacetActive ? .fill : .none)
        }
    }

    private var formatFacetActive: Bool {
        !vm.filter.formats.isEmpty || vm.filter.includeNotOwned
            || vm.filter.multipleCopies || vm.filter.duplicateCopies || vm.filter.includeSubscriptionOnly
    }

    // Playtime bands (< 4 h … > 200 h) over effective playtime, falling back to the
    // best IGDB estimate (main → rushed → completionist) when unplayed; plus
    // "No Estimate" for games with no time info at all (PLAN §6.4/§8, §5.3).
    private var playtimeMenu: some View {
        Menu {
            ForEach(PlaytimeBucket.allCases) { bucket in
                Toggle(bucket.label, isOn: membership(\.playtimes, bucket))
            }
            Divider()
            Toggle("No Estimate", isOn: flag(\.includeNoTimeEstimate))
                .help("Games with no completion time at all — nothing to fetch — which impairs Play Next.")
            Toggle("Suspicious Estimate", isOn: flag(\.includeSuspiciousEstimate))
                .help("Games whose completion times look wrong — out of order, or a completionist far longer than the main story — worth refreshing from HowLongToBeat.")
            Divider()
            Text("Uses your time, or the IGDB estimate when unplayed.")
            if playtimeFacetActive {
                Divider()
                Button("Clear") { clearPlaytimeFacet() }
            }
        } label: {
            Label("Playtime", systemImage: "clock")
                .symbolVariant(playtimeFacetActive ? .fill : .none)
        }
    }

    private var playtimeFacetActive: Bool {
        !vm.filter.playtimes.isEmpty || vm.filter.includeNoTimeEstimate || vm.filter.includeSuspiciousEstimate
    }

    // Platform multi-filter, usable from any scope incl. "All" (in-use platforms).
    private var platformMenu: some View {
        Menu {
            if vm.platforms.isEmpty {
                Button("No platforms yet") {}.disabled(true)
            } else {
                ForEach(vm.platforms) { platform in
                    Toggle(platform.name, isOn: membership(\.platforms, platform.id))
                }
                if !vm.filter.platforms.isEmpty {
                    Divider()
                    Button("Clear") { clear(\.platforms) }
                }
            }
        } label: {
            Label("Platform", systemImage: "gamecontroller")
                .symbolVariant(vm.filter.platforms.isEmpty ? .none : .fill)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: vm.sortBinding) {
                ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Toggle("Ascending", isOn: vm.filterBinding(\.ascending))
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
    }

    // MARK: Filter binding helpers

    private func membership<T: Hashable>(
        _ keyPath: WritableKeyPath<LibraryFilter, Set<T>>,
        _ value: T
    ) -> Binding<Bool> {
        Binding(
            get: { vm.filter[keyPath: keyPath].contains(value) },
            set: { isOn in
                var f = vm.filter
                if isOn { f[keyPath: keyPath].insert(value) } else { f[keyPath: keyPath].remove(value) }
                vm.setFilter(f)
            }
        )
    }

    private func clear<T>(_ keyPath: WritableKeyPath<LibraryFilter, Set<T>>) {
        var f = vm.filter
        f[keyPath: keyPath].removeAll()
        vm.setFilter(f)
    }

    /// A binding to a Bool facet flag (e.g. the "Unrated" / "Not Played" toggles).
    private func flag(_ keyPath: WritableKeyPath<LibraryFilter, Bool>) -> Binding<Bool> {
        Binding(
            get: { vm.filter[keyPath: keyPath] },
            set: { isOn in
                var f = vm.filter
                f[keyPath: keyPath] = isOn
                vm.setFilter(f)
            }
        )
    }

    /// "Clear" for the tier / status / format menus resets both the value set and
    /// that menu's extra facet flags ("Unrated" / "Not Played" · "No Status" /
    /// "Not Owned").
    private func clearTierFacet() {
        var f = vm.filter
        f.tierIDs.removeAll()
        f.includeUnrated = false
        vm.setFilter(f)
    }

    private func clearStatusFacet() {
        var f = vm.filter
        f.statuses.removeAll()
        f.includeNotPlayed = false
        f.includeNoStatus = false
        vm.setFilter(f)
    }

    private func clearFormatFacet() {
        var f = vm.filter
        f.formats.removeAll()
        f.includeNotOwned = false
        f.multipleCopies = false
        f.duplicateCopies = false
        f.includeSubscriptionOnly = false
        vm.setFilter(f)
    }

    private func clearPlaytimeFacet() {
        var f = vm.filter
        f.playtimes.removeAll()
        f.includeNoTimeEstimate = false
        f.includeSuspiciousEstimate = false
        vm.setFilter(f)
    }
}

/// A transient banner pinned to the bottom of the content (PLAN §8 feedback).
private struct BannerView: View {
    let banner: LibraryBanner
    var onAction: (() -> Void)? = nil
    var onSecondaryAction: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(banner.message).font(.callout)
            Spacer(minLength: 8)
            if let title = banner.secondaryActionTitle, let onSecondaryAction {
                Button(title) { onSecondaryAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("banner.secondaryAction")
            }
            if let title = banner.actionTitle, let onAction {
                Button(title) { onAction() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("banner.action")
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.4)))
        .frame(maxWidth: 460)
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var tint: Color {
        switch banner.kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#if DEBUG
#Preview("Root — samples") {
    RootView(vm: LibraryViewModel(dataSource: PreviewLibraryDataSource.large))
        .frame(width: 1000, height: 680)
}

#Preview("Root — empty") {
    RootView(vm: LibraryViewModel(dataSource: PreviewLibraryDataSource.empty))
        .frame(width: 1000, height: 680)
}
#endif
