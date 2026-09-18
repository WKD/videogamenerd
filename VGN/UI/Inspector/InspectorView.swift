import SwiftUI

/// The trailing inspector (PLAN §8, toggled by ⌘I). Skeleton driven by
/// `GameSummary` — a richer `GameDetail` from the DB lane replaces the value
/// type next wave, and the owned/played/tier controls become real writes then
/// (their closures are already routed through the view model). Handles the
/// empty, single- and multi-selection states.
struct InspectorView: View {
    @Bindable var vm: LibraryViewModel

    var body: some View {
        Group {
            switch vm.selectedGames.count {
            case 0: emptyState
            case 1: singleGame(vm.selectedGames[0])
            default: multiSelection(vm.selectedGames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Empty

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No selection", systemImage: "sidebar.right")
        } description: {
            Text("Select a game to see its details.")
        }
    }

    // MARK: Single

    private func singleGame(_ game: GameSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorCover(game: game, loader: vm.coverLoader)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title).font(.title2.bold())
                    if let year = game.year {
                        Text(String(year)).foregroundStyle(.secondary)
                    }
                }

                if !game.platformIDs.isEmpty {
                    FlowChips(slugs: game.platformIDs)
                }

                Divider()

                // Owned / Played. Writes are stubbed this wave, so the toggles
                // route through the view model but won't persist until wiring.
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Owned", isOn: Binding(
                        get: { game.owned },
                        set: { vm.setOwned($0, for: [game.id]) }
                    ))
                    Toggle("Played", isOn: Binding(
                        get: { game.played },
                        set: { vm.setPlayed($0, for: [game.id]) }
                    ))
                }

                Divider()

                tierPicker(current: game.tierLetter, ids: [game.id])

                Divider()

                placeholderRow("Copies", "—", note: "Products arrive in milestone 3")
                placeholderRow("Playtime", "—", note: "Playtime arrives in milestone 5")

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    // MARK: Multi

    private func multiSelection(_ games: [GameSummary]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(games.count) games selected").font(.title3.bold())
            Text("Bulk actions apply to all selected games.")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            tierPicker(current: nil, ids: Set(games.map(\.id)))

            HStack {
                Button("Mark Owned") { vm.setOwned(true, for: Set(games.map(\.id))) }
                Button("Mark Played") { vm.setPlayed(true, for: Set(games.map(\.id))) }
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Pieces

    private func tierPicker(current: String?, ids: Set<Int64>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tier").font(.headline)
            HStack(spacing: 6) {
                ForEach(vm.tiers) { tier in
                    Button {
                        vm.setTier(tier.letter, for: ids)
                    } label: {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 26)
                            .opacity(current == nil || current == tier.letter ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .help(tier.label)
                }
                Button {
                    vm.setTier(nil, for: ids)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear tier")
            }
        }
    }

    private func placeholderRow(_ title: String, _ value: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            Text(note).font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// The inspector's large cover, loaded through the cover seam with a placeholder
/// fallback.
private struct InspectorCover: View {
    let game: GameSummary
    let loader: any CoverLoading
    @State private var image: CGImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                PlaceholderCover(title: game.title, platformID: game.platformIDs.first)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: "\(game.id)#\(game.coverFile ?? "")") {
            guard let coverFile = game.coverFile else { image = nil; return }
            let px = CGSize(width: 240 * displayScale, height: 320 * displayScale)
            let loaded = await loader.thumbnail(for: coverFile, pixelSize: px)
            if !Task.isCancelled { image = loaded }
        }
    }
}

/// A simple wrapping row of platform chips.
private struct FlowChips: View {
    let slugs: [String]
    var body: some View {
        // A LazyVGrid gives cheap wrapping without a custom Layout.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(slugs, id: \.self) { PlatformChip(slug: $0) }
        }
    }
}

#if DEBUG
#Preview("Inspector — single") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start(); vm.selectOnly(1) }
        .frame(width: 300, height: 640)
}

#Preview("Inspector — empty") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start() }
        .frame(width: 300, height: 640)
}

#Preview("Inspector — multi") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
    InspectorView(vm: vm)
        .task { vm.start(); vm.selectedGameIDs = [1, 2, 3] }
        .frame(width: 300, height: 640)
}
#endif
