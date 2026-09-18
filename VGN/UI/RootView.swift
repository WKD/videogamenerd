import SwiftUI

/// The main window shell (PLAN §8): a plain `NavigationSplitView` (sidebar |
/// content) with a trailing `.inspector`. Not an AppKit split shell — PLAN §3
/// "Done differently".
struct RootView: View {
    @Bindable var vm: LibraryViewModel
    @FocusState private var searchFocused: Bool
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm)
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
        .task { vm.start() }
        .onAppear { vm.undoManager = undoManager }
        .onChange(of: vm.searchFocusRequests) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in vm.searchFieldFocused = focused }
        .sheet(isPresented: $vm.quickAddPresented) { manualAddSheet }
        .sheet(item: $vm.ownershipRequest) { request in
            OwnershipPickerSheet(request: request) { vm.ownershipRequest = nil }
        }
        .sheet(item: $vm.copyRemovalRequest) { request in
            CopyRemovalSheet(request: request) { vm.copyRemovalRequest = nil }
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
    }

    @ViewBuilder
    private var content: some View {
        ZStack(alignment: .bottom) {
            if vm.isRankingSelection {
                RankingPlaceholderView(selection: vm.selection)
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

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { vm.pendingConfirmation != nil },
            set: { if !$0 { vm.pendingConfirmation = nil } }
        )
    }

    // MARK: Toolbar (PLAN §8)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            TextField("Search", text: $vm.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, idealWidth: 220)
                .focused($searchFocused)
                .help("Search titles (⌘F)")
        }

        ToolbarItemGroup(placement: .automatic) {
            genreMenu
            decadeMenu
            tierMenu
            statusMenu
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
            .help("Toggle inspector (⌘I)")

            Button {
                vm.requestQuickAdd()
            } label: {
                Label("Add Game", systemImage: "plus")
            }
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
            if !vm.filter.tierIDs.isEmpty {
                Divider()
                Button("Clear") { clear(\.tierIDs) }
            }
        } label: {
            Label("Tier", systemImage: "chart.bar")
                .symbolVariant(vm.filter.tierIDs.isEmpty ? .none : .fill)
        }
    }

    private var statusMenu: some View {
        Menu {
            ForEach(PlayStatus.allCases) { status in
                Toggle(status.label, isOn: membership(\.statuses, status))
            }
            if !vm.filter.statuses.isEmpty {
                Divider()
                Button("Clear") { clear(\.statuses) }
            }
        } label: {
            Label("Status", systemImage: "flag")
                .symbolVariant(vm.filter.statuses.isEmpty ? .none : .fill)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: vm.filterBinding(\.sort)) {
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

    // MARK: Manual add (stop-gap until the Quick Add palette lands)

    private var manualAddSheet: some View {
        ManualAddSheet(
            model: ManualAddModel(defaultPlatform: vm.selection.platformSlug),
            onAdd: { draft in
                vm.quickAddPresented = false
                Task { await vm.actions?.addManualGame(draft) }
            },
            onCancel: { vm.quickAddPresented = false }
        )
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
