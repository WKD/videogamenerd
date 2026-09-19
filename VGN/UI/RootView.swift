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
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
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
            if !vm.isRankingSelection && !vm.isPlayNextSelection {
                FilterChipsBar(vm: vm)
            }
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
                } else {
                    LibraryGridView(vm: vm)
                }
                if let banner = vm.banner {
                    BannerView(banner: banner) { vm.dismissBanner() }
                        .padding(12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.banner)
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
            formatMenu
            playtimeMenu
            platformMenu
            sortMenu

            Slider(value: $vm.gridCellWidth,
                   in: LibraryViewModel.minCellWidth...LibraryViewModel.maxCellWidth)
                .frame(width: 90)
                .help("Grid size")

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

    private var statusFacetActive: Bool {
        !vm.filter.statuses.isEmpty || vm.filter.includeNotPlayed || vm.filter.includeNoStatus
    }

    // Ownership format (physical / digital / ROM), driven by ProductFormat.
    private var formatMenu: some View {
        Menu {
            ForEach(ProductFormat.allCases, id: \.self) { format in
                Toggle(format.label, isOn: membership(\.formats, format))
            }
            Divider()
            Toggle("Not Owned", isOn: flag(\.includeNotOwned))
            if !vm.filter.formats.isEmpty || vm.filter.includeNotOwned {
                Divider()
                Button("Clear") { clearFormatFacet() }
            }
        } label: {
            Label("Format", systemImage: "opticaldisc")
                .symbolVariant(vm.filter.formats.isEmpty && !vm.filter.includeNotOwned ? .none : .fill)
        }
    }

    // Playtime bands (< 10 h … > 200 h) over effective playtime, falling back to the
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
        !vm.filter.playtimes.isEmpty || vm.filter.includeNoTimeEstimate
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
        vm.setFilter(f)
    }

    private func clearPlaytimeFacet() {
        var f = vm.filter
        f.playtimes.removeAll()
        f.includeNoTimeEstimate = false
        vm.setFilter(f)
    }
}

/// A transient banner pinned to the bottom of the content (PLAN §8 feedback).
private struct BannerView: View {
    let banner: LibraryBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(banner.message).font(.callout)
            Spacer(minLength: 8)
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
