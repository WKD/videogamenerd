import SwiftUI

/// The ROM Catalogue browser (PLAN §15) — the sidebar "Batocera ▸ ROM Catalogue" destination.
/// A wholly separate view from the library grid: it reads only `rom_catalog` (through
/// ``RomCatalogueModel``), shows the shelf per system with search / sort / filters, and offers
/// "Add to Library…", "Not Interested" and "Show in Finder". The library, its counts, stats,
/// ranking and export never see any of it.
struct RomCatalogueView: View {
    @Environment(\.batoceraEnvironment) private var env
    @State private var model: RomCatalogueModel?

    var body: some View {
        Group {
            if let env, let model {
                RomCatalogueContent(env: env, model: model)
            } else {
                ContentUnavailableView("ROM Catalogue unavailable",
                                       systemImage: "externaldrive",
                                       description: Text("The Batocera catalogue isn't wired up."))
            }
        }
        .task {
            guard model == nil, let env else { return }
            let m = RomCatalogueModel(catalog: env.catalog, thumbnails: env.thumbnails)
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
        Button("Add to Library…") { env.addToLibrary?(Array(model.selection)) }
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

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    RomCatalogueRow(
                        entry: entry, env: env,
                        isSelected: model.selection.contains(entry.id),
                        loader: model.thumbnails,
                        onTap: { model.selectOnly(entry.id) },
                        onCommandTap: { model.toggle(entry.id) },
                        onAdd: { env.addToLibrary?(model.actionIDs(for: entry.id)) },
                        onNotInterested: { markNotInterested(entry.id) },
                        onInspect: { gid in env.inspectGame?(gid) })
                    Divider()
                    .onAppear { if entry.id == model.entries.last?.id { model.loadMore() } }
                }
                if model.isLoading {
                    ProgressView().controlSize(.small).padding(8)
                }
            }
        }
    }

    private func markNotInterested(_ id: Int64) {
        guard let entry = model.entries.first(where: { $0.id == id }) else { return }
        let catalog = env.catalog
        Task { try? await catalog.setNotInterested(catalogID: id) }
        model.reload()
        _ = entry
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
                Text(entry.name).font(.body).lineLimit(1)
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
