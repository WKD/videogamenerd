import SwiftUI

/// The Vault browser (PLAN §16) — the sidebar "THE VAULT ▸ Batocera ROMs / PS Plus"
/// destination. A wholly separate view from the library grid: it reads only `rom_catalog`
/// (through ``RomCatalogueModel``), scoped to the selected source, shows the shelf per system
/// with search / sort / filters, and offers "Add to Library…", "Not Interested" and (per
/// source) "Show in Finder" / "Open in PlayStation Store". The library, its counts, stats,
/// ranking and export never see any of it.
struct RomCatalogueView: View {
    /// The Vault source this browser is scoped to (PLAN §16).
    var source: VaultSource = .batocera
    @Environment(\.batoceraEnvironment) private var env
    @State private var model: RomCatalogueModel?

    var body: some View {
        Group {
            if let env, let model {
                RomCatalogueContent(env: env, model: model)
            } else {
                ContentUnavailableView("The Vault is unavailable",
                                       systemImage: "archivebox",
                                       description: Text("The Vault isn't wired up."))
            }
        }
        // Rebuild the model when the source changes (switching Vault rows reuses this view).
        .task(id: source) {
            guard let env else { return }
            let m = RomCatalogueModel(catalog: env.catalog, source: source, thumbnails: env.thumbnails)
            model = m
            m.start()
        }
    }
}

/// The catalogue body, split out so it takes a non-optional model + environment.
struct RomCatalogueContent: View {
    let env: BatoceraEnvironment
    @Bindable var model: RomCatalogueModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
        }
        .sheet(item: $model.findMatchModel) { linkModel in
            IGDBLinkSheet(model: linkModel)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                systemMenu
                TextField("Search the catalogue", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                sortMenu
                Spacer()
                selectionActions
            }
            filterChips
        }
        .padding(12)
    }

    private var systemMenu: some View {
        Menu {
            Button {
                model.selectedSystem = nil
            } label: {
                Label("All Systems (\(model.totalAll))", systemImage: model.selectedSystem == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(model.systems) { s in
                Button {
                    model.selectedSystem = s.system
                } label: {
                    if model.selectedSystem == s.system {
                        Label("\(s.label) (\(s.count))", systemImage: "checkmark")
                    } else {
                        Text("\(s.label) (\(s.count))")
                    }
                }
            }
        } label: {
            Label(systemLabel, systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var systemLabel: String {
        guard let sys = model.selectedSystem else { return "All Systems" }
        return model.systems.first { $0.system == sys }?.label ?? sys
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.sort) {
                ForEach(RomCatalogStore.BrowseSort.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(RomCatalogStore.BrowseFilter.allCases) { f in
                Button {
                    model.filter = f
                } label: {
                    Text(f.label)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(model.filter == f ? Color.accentColor.opacity(0.25) : Color.clear,
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(.secondary.opacity(model.filter == f ? 0 : 0.3)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("romCatalogue.filter.\(f.rawValue)")
            }
            Spacer()
            Text("\(model.matchCount) game\(model.matchCount == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var selectionActions: some View {
        Button("Add to Library…") { addSelectionToLibrary() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.selection.isEmpty)
            .accessibilityIdentifier("romCatalogue.addToLibrary")
        Button("Not Interested") {
            for id in model.selection { markNotInterested(id) }
            model.clearSelection()
        }
        .controlSize(.small)
        .disabled(model.selection.isEmpty)
        .accessibilityIdentifier("romCatalogue.notInterested")
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if model.entries.isEmpty, !model.isLoading {
            vaultEmptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        row(for: entry)
                        Divider()
                        .onAppear { if entry.id == model.entries.last?.id { model.loadMore() } }
                    }
                    if model.isLoading {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
            }
        }
    }

    /// The Vault list empty states (PLAN §16): nothing in this shelf at all (source not set up),
    /// or everything filtered out. No Settings button — there is no programmatic open for a
    /// specific Settings tab today, so the sentence points there (noted in the hand-off).
    @ViewBuilder
    private var vaultEmptyState: some View {
        if model.totalAll == 0 {
            switch model.source {
            case .psn:
                EmptyStateView(
                    systemImage: "sparkles",
                    title: "No PS Plus games yet",
                    message: "Sync your PlayStation library in Settings ▸ PlayStation. PS Plus catalogue games you've only sampled land here, kept out of your library.",
                    accessibilityID: "vault.empty.unconfigured")
            default:
                EmptyStateView(
                    systemImage: "archivebox",
                    title: "No ROM catalogue yet",
                    message: "Point VGN at your Batocera share in Settings ▸ Batocera, then sync to browse the ROMs you can add.",
                    accessibilityID: "vault.empty.unconfigured")
            }
        } else {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "Nothing matches",
                message: "No games in the Vault match the current system, search or filter.",
                actions: isVaultFiltered
                    ? [EmptyStateAction(title: "Clear filters", isProminent: true,
                                        accessibilityID: "vault.empty.clearFilters") { clearVaultFilters() }]
                    : [],
                accessibilityID: "vault.empty.filtered")
        }
    }

    private var isVaultFiltered: Bool {
        !model.searchText.isEmpty || model.selectedSystem != nil
            || model.filter != RomCatalogStore.BrowseFilter.allCases.first
    }

    private func clearVaultFilters() {
        model.searchText = ""
        model.selectedSystem = nil
        if let first = RomCatalogStore.BrowseFilter.allCases.first { model.filter = first }
    }

    @ViewBuilder
    private func row(for entry: RomCatalogEntry) -> some View {
        if entry.vaultSource == .psn {
            VaultBrowserRow(
                entry: entry, env: env,
                isSelected: model.selection.contains(entry.id),
                onTap: { model.selectOnly(entry.id) },
                onCommandTap: { model.toggle(entry.id) },
                onAdd: { model.addPSPlusToLibrary(ids: model.actionIDs(for: entry.id)) },
                onNotInterested: { markNotInterested(entry.id) },
                onFindMatch: { openFindMatch(entry) },
                onInspect: { gid in env.inspectGame?(gid) })
        } else {
            RomCatalogueRow(
                entry: entry, env: env,
                isSelected: model.selection.contains(entry.id),
                loader: model.thumbnails,
                onTap: { model.selectOnly(entry.id) },
                onCommandTap: { model.toggle(entry.id) },
                onAdd: { env.addToLibrary?(model.actionIDs(for: entry.id)) },
                onNotInterested: { markNotInterested(entry.id) },
                onInspect: { gid in env.inspectGame?(gid) })
        }
    }

    /// "Add to Library…" for the top-bar multi-selection, routed by source: PS Plus commits
    /// owned-via-subscription copies; Batocera opens the promotion review.
    private func addSelectionToLibrary() {
        let ids = Array(model.selection)
        guard !ids.isEmpty else { return }
        if model.source == .psn {
            model.addPSPlusToLibrary(ids: ids)
            model.clearSelection()
        } else {
            env.addToLibrary?(ids)
        }
    }

    /// Open the manual "Find match…" sheet for a PS Plus entry, reusing the reconcile link
    /// sheet's search UI (PLAN §16). On choosing a game, its traits are fetched and persisted.
    private func openFindMatch(_ entry: RomCatalogEntry) {
        guard let seam = env.findMatch else { return }
        let title = PSNMapping.cleanMatchTitle(entry.name)
        let platforms = [entry.platformID].compactMap { $0 }
        let linkModel = IGDBLinkModel(
            gameID: entry.id, currentTitle: title,
            platformSlugs: platforms, year: entry.releaseYear,
            isLinked: entry.igdbID != nil, prefill: title,
            searcher: seam.searcher, platformIGDBIDs: seam.platformIGDBIDs(entry.platformID))
        linkModel.onChoose = { choice in
            let apply = seam.apply
            Task {
                await apply(entry.id, choice.igdbID)
                model.findMatchModel = nil
                model.reload()
            }
        }
        linkModel.onCancel = { model.findMatchModel = nil }
        model.findMatchModel = linkModel
    }

    private func markNotInterested(_ id: Int64) {
        let catalog = env.catalog
        Task { try? await catalog.setNotInterested(catalogID: id) }
        model.reload()
    }
}

/// One catalogue row: thumbnail, title, system pill, year, genre, ★ rating, play time and an
/// "In Library" marker linking to the promoted game.
struct RomCatalogueRow: View {
    let entry: RomCatalogEntry
    let env: BatoceraEnvironment
    let isSelected: Bool
    let loader: BatoceraThumbnailLoader?
    let onTap: () -> Void
    let onCommandTap: () -> Void
    let onAdd: () -> Void
    let onNotInterested: () -> Void
    let onInspect: (Int64) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RomCatalogThumb(entry: entry, loader: loader)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2).foregroundStyle(.orange)
                            .appKitTooltip("★ a favourite on your Batocera")
                            .accessibilityIdentifier("romCatalogue.favourite.\(entry.id)")
                    }
                    Text(entry.name).font(.body).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(systemLabel)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.2), in: Capsule())
                    if let year = entry.releaseYear { Text(String(year)).font(.caption2).foregroundStyle(.secondary) }
                    if let genre = entry.genre, !genre.isEmpty {
                        Text(genre).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu { contextMenu }
    }

    private var trailing: some View {
        HStack(spacing: 10) {
            if let rating = entry.rating {
                Label(String(format: "%.0f", rating * 100), systemImage: "star.fill")
                    .font(.caption2).foregroundStyle(.yellow)
                    .labelStyle(.titleAndIcon)
            }
            if entry.gameTimeSeconds > 0 {
                Text(PlaytimeParser.format(seconds: entry.gameTimeSeconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let gid = entry.promotedGameID {
                Button {
                    onInspect(gid)
                } label: {
                    Label("In Library", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .help("Already in your library — click to reveal it.")
            }
        }
    }

    private var systemLabel: String {
        if let slug = BatoceraSystems.platformSlug(for: entry.system) { return PlatformLabels.short(slug) }
        return entry.system
    }

    @ViewBuilder
    private var contextMenu: some View {
        if entry.promotedGameID == nil {
            Button("Add to Library…") { onAdd() }
            Button("Not Interested") { onNotInterested() }
        }
        if env.isLive {
            Button("Show in Finder") { env.showInFinder(entry) }
        }
        if let gid = entry.promotedGameID {
            Button("Reveal in Library") { onInspect(gid) }
        }
    }
}
