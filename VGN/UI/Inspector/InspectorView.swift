import SwiftUI

/// The trailing inspector (PLAN §8, ⌘I). Single selection renders the live
/// ``GameDetail`` (kept fresh by the view model's detail observation): cover,
/// metadata, genres, platform chips, summary, owned copies, played + status,
/// tier + rank, and playtime (mine, editable, vs. IGDB averages). Multi-selection
/// offers bulk tier / played / status actions.
struct InspectorView: View {
    @Bindable var vm: LibraryViewModel

    var body: some View {
        Group {
            switch vm.selectedGameIDs.count {
            case 0:
                emptyState
            case 1:
                if let detail = vm.selectedDetail, detail.id == vm.selectedGameIDs.first {
                    SingleGameInspector(vm: vm, detail: detail)
                } else if let summary = vm.selectedGame {
                    // Detail still loading — show what the slim row already has.
                    SingleGameInspector(vm: vm, detail: GameDetail(previewFrom: summary))
                } else {
                    emptyState
                }
            default:
                multiSelection(vm.selectedGames)
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

    // MARK: Multi

    private func multiSelection(_ games: [GameSummary]) -> some View {
        let ids = Set(games.map(\.id))
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(games.count) games selected").font(.title3.bold())
                Text("Bulk actions apply to all selected games.")
                    .font(.callout).foregroundStyle(.secondary)

                Divider()

                TierPickerRow(tiers: vm.tiers, current: nil) { letter in
                    vm.setTier(letter, for: ids)
                }

                Divider()

                HStack {
                    Button("Mark Owned") { vm.setOwned(true, for: ids) }
                    Button("Mark Played") { vm.setPlayed(true, for: ids) }
                }

                StatusPickerRow(current: nil) { status in
                    Task { await vm.actions?.setStatus(ids: ids, status: status) }
                }

                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Single-game detail

private struct SingleGameInspector: View {
    @Bindable var vm: LibraryViewModel
    let detail: GameDetail

    private var ids: Set<Int64> { [detail.id] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InspectorCover(coverFile: detail.coverFile, title: detail.title,
                               platformID: detail.platformIDs.first, loader: vm.coverLoader)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.title).font(.title2.bold())
                    if let year = detail.year {
                        Text(String(year)).foregroundStyle(.secondary)
                    }
                }

                if !detail.genres.isEmpty {
                    Text(detail.genres.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }

                if !detail.platformIDs.isEmpty {
                    FlowChips(slugs: detail.platformIDs)
                }

                if let summary = detail.summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }

                Divider()
                playedStatusSection
                Divider()
                tierSection
                Divider()
                copiesSection
                Divider()
                playtimeSection

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    // MARK: Played + status

    private var playedStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Owned", isOn: Binding(
                get: { detail.owned },
                set: { vm.setOwned($0, for: ids) }
            ))
            Toggle("Played", isOn: Binding(
                get: { detail.played },
                set: { vm.setPlayed($0, for: ids) }
            ))
            if detail.played {
                StatusPickerRow(current: detail.status) { status in
                    Task { await vm.actions?.setStatus(ids: ids, status: status) }
                }
            }
        }
    }

    // MARK: Tier + rank

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TierPickerRow(tiers: vm.tiers, current: detail.tierLetter) { letter in
                vm.setTier(letter, for: ids)
            }
            Text(rankDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var rankDescription: String {
        if !detail.played { return "Only played games can be ranked." }
        if detail.tierID == nil { return "Unranked — press S…F to place it in a tier." }
        if detail.isUnplaced { return "Placed in tier, not yet ranked (unplaced)." }
        return "Ranked. (Overall position — “#12 overall” — arrives with ranking.)"
    }

    // MARK: Copies

    private var copiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Copies").font(.headline)
                Spacer()
                Button {
                    vm.actions?.requestAddCopy(gameID: detail.id, title: detail.title,
                                               platforms: detail.platformIDs)
                } label: {
                    Label("Add copy…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(vm.actions == nil)
            }

            if detail.copies.isEmpty {
                Text("Not owned. Press O or “Add copy…” to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(detail.copies) { copy in
                    copyRow(copy)
                }
            }
        }
    }

    private func copyRow(_ copy: GameDetail.Copy) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copyPrimaryLine(copy)).font(.callout)
                if copy.isCompilation {
                    Text("Part of \(copy.title ?? "a compilation") (\(copy.memberCount) games)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                vm.actions?.removeCopy(productID: copy.productID, gameTitle: detail.title)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(copy.isCompilation ? "Remove the whole compilation" : "Remove this copy")
            .disabled(vm.actions == nil)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    private func copyPrimaryLine(_ copy: GameDetail.Copy) -> String {
        var parts = [PlatformLabels.short(copy.platformID), copy.format.rawValue.capitalized]
        if let edition = copy.edition, !edition.isEmpty { parts.append(edition) }
        return parts.joined(separator: " · ")
    }

    // MARK: Playtime

    private var playtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playtime").font(.headline)
            PlaytimeEditor(detail: detail) { seconds in
                Task { await vm.actions?.setMyPlaytime(gameID: detail.id, seconds: seconds) }
            }
            if hasAverages {
                MeVsAverageBar(mine: detail.effectivePlaytimeS, average: detail.ttbNormallyS)
                averagesText
            } else {
                Text("Average completion times arrive with metadata (milestone 5).")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private var hasAverages: Bool {
        detail.ttbHastilyS != nil || detail.ttbNormallyS != nil || detail.ttbCompletelyS != nil
    }

    private var averagesText: some View {
        HStack(spacing: 10) {
            if let s = detail.ttbNormallyS {
                Text("Main \(PlaytimeParser.formatApprox(seconds: s))")
            }
            if let s = detail.ttbCompletelyS {
                Text("100% \(PlaytimeParser.formatApprox(seconds: s))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Reusable pieces

/// The tier picker used in both single and multi inspectors.
private struct TierPickerRow: View {
    let tiers: [TierInfo]
    let current: String?
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tier").font(.headline)
            HStack(spacing: 6) {
                ForEach(tiers) { tier in
                    Button {
                        onPick(tier.letter)
                    } label: {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 26)
                            .opacity(current == nil || current == tier.letter ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    .help(tier.label)
                }
                Button {
                    onPick(nil)
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
}

/// A status menu (Playing / Finished / 100% / Abandoned, or None).
private struct StatusPickerRow: View {
    let current: PlayStatus?
    let onPick: (PlayStatus?) -> Void

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            Menu(current?.label ?? "None") {
                Button("None") { onPick(nil) }
                Divider()
                ForEach(PlayStatus.allCases) { status in
                    Button(status.label) { onPick(status) }
                }
            }
            .fixedSize()
        }
    }
}

/// The editable "my playtime" field. Accepts `45h`, `45:30`, `2d`… via
/// `PlaytimeParser`; commits on return / focus loss; rejects garbage.
private struct PlaytimeEditor: View {
    let detail: GameDetail
    let onCommit: (Int?) -> Void

    @State private var text: String = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text("Mine")
            TextField("e.g. 45h, 45:30, 2d", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)
                .foregroundStyle(invalid ? Color.red : Color.primary)
            if !text.isEmpty {
                Button {
                    text = ""
                    onCommit(nil)
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: detail.id) { text = displayText }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private var displayText: String {
        guard let s = detail.myPlaytimeS, s > 0 else { return "" }
        return PlaytimeParser.format(seconds: s)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            invalid = false
            onCommit(nil)
            return
        }
        if let seconds = PlaytimeParser.seconds(from: trimmed) {
            invalid = false
            onCommit(seconds)
        } else {
            invalid = true
        }
    }
}

/// A minimal "me vs. average" bar (polished later — PLAN milestone 5).
private struct MeVsAverageBar: View {
    let mine: Int?
    let average: Int?

    var body: some View {
        GeometryReader { geo in
            let maxV = Double(max(mine ?? 0, average ?? 0, 1))
            VStack(alignment: .leading, spacing: 4) {
                bar(width: geo.size.width, value: mine, of: maxV, color: .accentColor, label: "You")
                bar(width: geo.size.width, value: average, of: maxV, color: .secondary, label: "Avg")
            }
        }
        .frame(height: 30)
    }

    private func bar(width: CGFloat, value: Int?, of maxV: Double, color: Color, label: String) -> some View {
        let fraction = value.map { Double($0) / maxV } ?? 0
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 10)
            RoundedRectangle(cornerRadius: 3).fill(color)
                .frame(width: max(2, width * fraction), height: 10)
        }
        .accessibilityLabel("\(label): \(value.map { PlaytimeParser.format(seconds: $0) } ?? "—")")
    }
}

/// The inspector's large cover, loaded through the cover seam with a placeholder
/// fallback.
private struct InspectorCover: View {
    let coverFile: String?
    let title: String
    let platformID: String?
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
                PlaceholderCover(title: title, platformID: platformID)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: "\(coverFile ?? "")") {
            guard let coverFile else { image = nil; return }
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
