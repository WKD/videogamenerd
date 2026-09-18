import SwiftUI

/// The main window shell (PLAN §8): a plain `NavigationSplitView` (sidebar |
/// content) with a trailing `.inspector`. Not an AppKit split shell — PLAN §3
/// "Done differently".
struct RootView: View {
    @Bindable var vm: LibraryViewModel
    @FocusState private var searchFocused: Bool

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
        .onChange(of: vm.searchFocusRequests) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in vm.searchFieldFocused = focused }
        .sheet(isPresented: $vm.quickAddPresented) { quickAddPlaceholder }
        // Expose the view model to the scene's Commands (⌘I / ⌘F / View menu).
        .focusedSceneValue(\.library, vm)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isRankingSelection {
            RankingPlaceholderView(selection: vm.selection)
        } else {
            LibraryGridView(vm: vm)
        }
    }

    // MARK: Toolbar (PLAN §8)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            TextField("Search", text: vm.filterBinding(\.searchText))
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

    // Genres need catalog data (milestone 2) — structural placeholder for now.
    private var genreMenu: some View {
        Menu {
            Button("Genres load in milestone 2") {}.disabled(true)
        } label: { Label("Genre", systemImage: "theatermasks") }
    }

    private var decadeMenu: some View {
        Menu {
            ForEach(Array(stride(from: 1970, through: 2020, by: 10)), id: \.self) { decade in
                Toggle("\(decade)s", isOn: membership(\.decades, decade))
            }
            if !vm.filter.decades.isEmpty {
                Divider()
                Button("Clear") { clear(\.decades) }
            }
        } label: {
            Label("Decade", systemImage: "calendar")
                .symbolVariant(vm.filter.decades.isEmpty ? .none : .fill)
        }
    }

    // Tier + Status can already work — their domains are known now (PLAN §8).
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

    // MARK: Quick Add placeholder (real palette is another lane, next wave)

    private var quickAddPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "command").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Quick Add").font(.title2.bold())
            Text("The Spotlight-style Quick Add palette arrives in milestone 1.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Close") { vm.quickAddPresented = false }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(width: 400)
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
