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
        .accessibilityIdentifier(A11yID.inspector)
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

                if games.count > 1 {
                    Divider()
                    Button {
                        vm.onGroupAsCompilation(ids)
                    } label: {
                        Label("Group as compilation…", systemImage: "square.stack.3d.up")
                    }
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
                               platformID: detail.platformIDs.first, loader: vm.coverLoader,
                               onDropCover: { url in vm.importCover(gameID: detail.id, from: url) })
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)

                VStack(alignment: .leading, spacing: 4) {
                    Text(detail.title).font(.title2.bold())
                    if let year = detail.year {
                        Text(String(year)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        vm.refreshMetadata(gameID: detail.id)
                    } label: {
                        Label("Refresh metadata", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Re-fetch metadata, cover and completion times from IGDB.")

                    Button {
                        vm.requestChooseCover(gameID: detail.id)
                    } label: {
                        Label("Choose Cover…", systemImage: "photo.stack")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!vm.canChooseCover)
                    .help("Browse every cover from all providers, or pick an image file.")

                    if detail.userEditedCover {
                        Button {
                            vm.removeCustomCover(gameID: detail.id)
                        } label: {
                            Label("Remove custom cover", systemImage: "photo.badge.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .help("Drop the hand-picked cover and fetch one from IGDB / libretro again.")
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
            .accessibilityIdentifier(A11yID.inspectorPlayedToggle)
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
            TierPickerRow(tiers: vm.tiers, current: detail.tierLetter,
                          score: vm.selectedScoreLine?.score) { letter in
                vm.setTier(letter, for: ids)
            }
            .accessibilityIdentifier(A11yID.inspectorTierChip)
            .accessibilityValue(detail.tierLetter ?? "Unranked")
            scoreLineView
        }
    }

    /// The derived-score line (PLAN §7): "9.6 · #4 overall · A, #2 of 14" for a
    /// placed game; "~8.5 · unplaced in A" + "Place now" for an unplaced one;
    /// a plain hint for unranked / unplayed games (nothing but the tier picker).
    @ViewBuilder
    private var scoreLineView: some View {
        if !detail.played {
            Text("Only played games can be ranked.")
                .font(.caption).foregroundStyle(.secondary)
        } else if detail.tierID == nil {
            Text("Unranked — press ⇧S…⇧F to place it in a tier.")
                .font(.caption).foregroundStyle(.secondary)
        } else if let line = vm.selectedScoreLine, line.isPlaced {
            Text(line.summary())
                .font(.callout.weight(.medium))
                .monospacedDigit()
        } else if let line = vm.selectedScoreLine {
            HStack(spacing: 8) {
                Text(line.summary())
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Button("Place now") { vm.select(.duel) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Run this game's placement duels now.")
            }
        } else {
            // Placed in a tier, score still resolving.
            Text(detail.isUnplaced ? "Placed in tier, not yet ranked (unplaced)."
                                   : "Ranked.")
                .font(.caption).foregroundStyle(.secondary)
        }
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

    @ViewBuilder
    private func copyRow(_ copy: GameDetail.Copy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copyPrimaryLine(copy)).font(.callout)
                    if copy.isCompilation {
                        // PLAN §8: "Part of *Metal Gear Solid: The Legacy Collection* (PS3) · n games".
                        (Text("Part of ")
                         + Text(copy.title ?? "a compilation").italic()
                         + Text(" (\(PlatformLabels.short(copy.platformID))) · ^[\(copy.memberCount) game](inflect: true)"))
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

            if copy.isCompilation {
                compilationMembers(copy)
                Button {
                    vm.editCompilation(productID: copy.productID)
                } label: {
                    Label("Edit compilation…", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }

    /// The inline member list of a compilation copy — click a member to select it
    /// (PLAN §8). The currently-shown game is highlighted, not clickable.
    private func compilationMembers(_ copy: GameDetail.Copy) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(zip(copy.memberIDs, copy.memberTitles)), id: \.0) { id, title in
                if id == detail.id {
                    Text("• \(title)")
                        .font(.caption).fontWeight(.semibold)
                } else {
                    Button {
                        vm.selectOnly(id)
                    } label: {
                        Text("• \(title)")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.leading, 4)
    }

    private func copyPrimaryLine(_ copy: GameDetail.Copy) -> String {
        var parts = [PlatformLabels.short(copy.platformID), copy.format.rawValue.capitalized]
        if let edition = copy.edition, !edition.isEmpty { parts.append(edition) }
        return parts.joined(separator: " · ")
    }

    // MARK: Playtime

    private var playtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Playtime").font(.headline)
            PlaytimeEditor(detail: detail) { seconds in
                Task { await vm.actions?.setMyPlaytime(gameID: detail.id, seconds: seconds) }
            }
            if let psn = detail.psnPlaytimeS, psn > 0 {
                psnRow(psn)
            }
            if hasAverages {
                averagesText
                MeVsAverageBar(bar: bar)
            } else {
                Text("Average completion times arrive with metadata.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            hltbLink
        }
    }

    private var bar: PlaytimeBar {
        PlaytimeBar.make(mineSeconds: detail.effectivePlaytimeS,
                         rushed: detail.ttbHastilyS, main: detail.ttbNormallyS,
                         completionist: detail.ttbCompletelyS)
    }

    private var hasAverages: Bool {
        detail.ttbHastilyS != nil || detail.ttbNormallyS != nil || detail.ttbCompletelyS != nil
    }

    /// PSN playtime, shown with the "manual wins" note when a manual value overrides
    /// it (PLAN §6.4 — both are kept, manual is effective).
    private func psnRow(_ psn: Int) -> some View {
        HStack {
            Text("PSN").foregroundStyle(.secondary)
            Text(PlaytimeParser.format(seconds: psn)).foregroundStyle(.secondary)
            if detail.myPlaytimeS != nil {
                Text("(manual wins)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.callout)
    }

    private var averagesText: some View {
        // PLAN §10: "Main ≈ 32 h · Rushed ≈ 27 h · Completionist ≈ 61 h" + source.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                if let s = detail.ttbNormallyS { Text("Main \(PlaytimeParser.formatApprox(seconds: s))") }
                if let s = detail.ttbHastilyS { Text("Rushed \(PlaytimeParser.formatApprox(seconds: s))") }
                if let s = detail.ttbCompletelyS { Text("Completionist \(PlaytimeParser.formatApprox(seconds: s))") }
            }
            if let source = detail.ttbSource, !source.isEmpty {
                Text("Source: \(source)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// "Open on HowLongToBeat" — a plain search link, no scraping (PLAN §5.3/§6.4).
    @ViewBuilder
    private var hltbLink: some View {
        if let url = HowLongToBeatLink.searchURL(title: detail.title) {
            Link(destination: url) {
                Label("Open on HowLongToBeat", systemImage: "arrow.up.forward.square")
            }
            .font(.caption)
        }
    }
}

// MARK: - Reusable pieces

/// The tier picker used in both single and multi inspectors.
private struct TierPickerRow: View {
    let tiers: [TierInfo]
    let current: String?
    /// The current game's derived score, shown in the tooltip of the button for
    /// the game's *current* tier (nil for the multi-selection picker).
    var score: DerivedScoreValue? = nil
    let onPick: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tier").font(.headline)
            HStack(spacing: 6) {
                ForEach(tiers) { tier in
                    Button {
                        onPick(tier.letter)
                    } label: {
                        // The chip's own hover help is suppressed here so the single
                        // tooltip lives on the outermost hit-testable view (the Button);
                        // two nested `.help`s never fire reliably on macOS.
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 26,
                                 showsLabelOnHover: false)
                            .opacity(current == nil || current == tier.letter ? 1 : 0.4)
                    }
                    .buttonStyle(.plain)
                    // Only the game's current tier carries its derived score.
                    .help(TierChip.hoverText(letter: tier.letter, label: tier.label, labels: [:],
                                             score: tier.letter == current ? score : nil))
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

/// A status menu (Playing / Finished / 100% / Abandoned, or None) with inspector
/// keyboard shortcuts (⌃⌘1…4 set a status, ⌃⌘0 clears — PLAN §12 / milestone 5).
private struct StatusPickerRow: View {
    let current: PlayStatus?
    let onPick: (PlayStatus?) -> Void

    private static let shortcuts: [PlayStatus: KeyEquivalent] = [
        .playing: "1", .finished: "2", .completed: "3", .abandoned: "4",
    ]

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            Menu(current?.label ?? "None") {
                Button("None") { onPick(nil) }
                    .keyboardShortcut("0", modifiers: [.control, .command])
                Divider()
                ForEach(PlayStatus.allCases) { status in
                    Button(status.label) { onPick(status) }
                        .keyboardShortcut(Self.shortcuts[status] ?? "0", modifiers: [.control, .command])
                }
            }
            .fixedSize()
            .accessibilityIdentifier(A11yID.inspectorStatus)
            .accessibilityValue(current?.label ?? "None")
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
                .accessibilityIdentifier(A11yID.inspectorPlaytimeField)
                .accessibilityValue(invalid ? "Invalid" : text)
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

/// The "me vs. average" bar (PLAN §6.4): my playtime as a fill, with the IGDB
/// rushed / main / completionist averages as labelled markers on the same scale.
/// Geometry is the pure ``PlaytimeBar``; this only draws it.
private struct MeVsAverageBar: View {
    let bar: PlaytimeBar

    private let height: CGFloat = 12

    var body: some View {
        if bar.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    let width = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: height)
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(bar.mineSeconds == nil ? 0 : 3, width * bar.fillFraction),
                                   height: height)
                        // Average markers.
                        ForEach(bar.markers) { marker in
                            Rectangle()
                                .fill(.primary.opacity(0.55))
                                .frame(width: 2, height: height + 6)
                                .offset(x: min(width - 2, width * marker.fraction))
                        }
                    }
                }
                .frame(height: height + 6)

                HStack(spacing: 10) {
                    if let mine = bar.mineSeconds {
                        Label("You \(PlaytimeParser.format(seconds: mine))", systemImage: "person.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                    ForEach(bar.markers) { marker in
                        Text("\(marker.label) \(PlaytimeParser.formatApprox(seconds: marker.seconds))")
                    }
                    if bar.exceedsCompletionist {
                        Text("· beyond 100%").foregroundStyle(.orange)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let mine = bar.mineSeconds { parts.append("Your playtime \(PlaytimeParser.format(seconds: mine))") }
        for marker in bar.markers {
            parts.append("\(marker.label) average \(PlaytimeParser.formatApprox(seconds: marker.seconds))")
        }
        if bar.exceedsCompletionist { parts.append("beyond the completionist estimate") }
        return parts.joined(separator: ", ")
    }
}

/// The inspector's large cover, loaded through the cover seam with a placeholder
/// fallback.
private struct InspectorCover: View {
    let coverFile: String?
    let title: String
    let platformID: String?
    let loader: any CoverLoading
    var onDropCover: (URL) -> Void = { _ in }
    @State private var image: CGImage?
    @State private var isDropTargeted = false
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
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.isFileURL }) else { return false }
            onDropCover(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
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

#Preview("Me-vs-average bar") {
    VStack(alignment: .leading, spacing: 24) {
        MeVsAverageBar(bar: .make(mineSeconds: 40 * 3600, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
        MeVsAverageBar(bar: .make(mineSeconds: 120 * 3600, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
        MeVsAverageBar(bar: .make(mineSeconds: nil, rushed: 27 * 3600,
                                  main: 32 * 3600, completionist: 61 * 3600))
    }
    .padding(24)
    .frame(width: 300)
}
#endif
