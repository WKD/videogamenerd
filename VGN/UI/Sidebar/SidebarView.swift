import SwiftUI

/// The library sidebar (PLAN §8): LIBRARY smart lists, RANKINGS destinations
/// and PLATFORMS grouped by manufacturer as collapsible groups, with live count
/// badges. `List(selection:)` is bound to `SidebarSelection?` and **every**
/// `.tag(…)` is a `SidebarSelection` — romlord's documented gotcha: if a tag's
/// static type differs from the selection type, selection silently breaks
/// (see `SidebarSelection.swift`). `taggedRow` funnels every row through one
/// `.tag(SidebarSelection)` call so the type can never drift.
struct SidebarView: View {
    @Bindable var vm: LibraryViewModel
    /// The background-enrichment status footer (PLAN §9); nil in previews.
    var enrichment: EnrichmentStatusModel?

    /// Whether the "By Length" pace popover is open (view-local UI state).
    @State private var showPacePopover = false

    private var platformGroups: [SidebarPlatformGrouping.Group] {
        SidebarPlatformGrouping.groups(platforms: vm.platforms, counts: vm.counts)
    }

    /// The current pace-derived shelf edges (for row subtitles + tooltips).
    private var lengthBounds: LengthBounds { LengthShelf.bounds(for: vm.playPace) }

    var body: some View {
        List(selection: vm.sidebarSelectionBinding) {
            Section("Library") {
                ForEach(SidebarSelection.smartLists) { sel in
                    taggedRow(sel) {
                        Label(Self.title(for: sel), systemImage: Self.icon(for: sel))
                            .badge(badge(for: sel))
                    }
                }
                // "Unlinked" — games with no IGDB link (PLAN §5.1). Shown ONLY when it
                // has games (like "Unmeasured"), so a fully-linked library never sees it.
                if (vm.counts.count(for: .unlinked) ?? 0) > 0 {
                    taggedRow(.unlinked) {
                        Label(Self.title(for: .unlinked), systemImage: Self.icon(for: .unlinked))
                            .badge(badge(for: .unlinked))
                    }
                    .appKitTooltip("Games not matched to an IGDB entry — no metadata, "
                                   + "time estimates or recommendations. Link them here.")
                }
                // "Bundles to Expand" — games whose title looks like an unexpanded bundle
                // (PLAN §5.1). Right under Unlinked, shown ONLY when it has games.
                if (vm.counts.count(for: .bundlesToExpand) ?? 0) > 0 {
                    taggedRow(.bundlesToExpand) {
                        Label(Self.title(for: .bundlesToExpand), systemImage: Self.icon(for: .bundlesToExpand))
                            .badge(badge(for: .bundlesToExpand))
                    }
                    .appKitTooltip("Games that look like a Trilogy / Collection / Pack imported "
                                   + "as one game. Expand one into its member games — IGDB is "
                                   + "checked when you click.")
                }
                // "DLC & Expansions" — games that are IGDB DLC / expansions / packs / seasons /
                // updates / mods, not games in their own right (PLAN §5.1). Shown ONLY when > 0.
                if (vm.counts.count(for: .dlcAndExpansions) ?? 0) > 0 {
                    taggedRow(.dlcAndExpansions) {
                        Label(Self.title(for: .dlcAndExpansions), systemImage: Self.icon(for: .dlcAndExpansions))
                            .badge(badge(for: .dlcAndExpansions))
                    }
                    .appKitTooltip("Add-on content matched to IGDB as DLC, an expansion, a pack, a "
                                   + "season, an update or a mod — not a game in its own right.")
                }
                // "Same Game, Two Entries" — an IGDB port whose parent game is also in the library
                // (PLAN §5.1). Shown ONLY when > 0; merge one into its original from here.
                if (vm.counts.count(for: .sameGameTwoEntries) ?? 0) > 0 {
                    taggedRow(.sameGameTwoEntries) {
                        Label(Self.title(for: .sameGameTwoEntries), systemImage: Self.icon(for: .sameGameTwoEntries))
                            .badge(badge(for: .sameGameTwoEntries))
                    }
                    .appKitTooltip("A port catalogued separately from the original you also own — "
                                   + "merge it into the original to keep one entry.")
                }
                // "Needs a 'Holds Up' Rating" — played games not yet judged "Holds up today?"
                // (PLAN §7b/§8). Shown ONLY when > 0; a game leaves it as soon as it is rated.
                if (vm.counts.count(for: .needsHoldsUpRating) ?? 0) > 0 {
                    taggedRow(.needsHoldsUpRating) {
                        Label(Self.title(for: .needsHoldsUpRating), systemImage: Self.icon(for: .needsHoldsUpRating))
                            .badge(badge(for: .needsHoldsUpRating))
                    }
                    .appKitTooltip("Played games you haven't judged yet: do they hold up today, are "
                                   + "they of their time, or too archaic to play now? Only Play Next "
                                   + "uses it — never your ranking.")
                }
            }

            Section("Rankings") {
                ForEach(SidebarSelection.rankingViews) { sel in
                    taggedRow(sel) {
                        Label(Self.title(for: sel), systemImage: Self.icon(for: sel))
                            .badge(badge(for: sel))
                    }
                }
            }

            lengthSection

            // "THE VAULT" — the Vault browser, one row per source (PLAN §16). Each row shown
            // ONLY when that source is non-empty; the counts come from a SEPARATE observation
            // (`vm.vaultCounts`), never the library counts, so 11 000 ROMs + PS Plus claims
            // never touch any library number.
            if vm.vaultCounts.total > 0 {
                Section("THE VAULT") {
                    ForEach(vm.vaultCounts.nonEmptySources) { src in
                        taggedRow(.vault(src)) {
                            Label(src.rowTitle, systemImage: src.icon)
                                .badge(vm.vaultCounts.count(src))
                        }
                        .appKitTooltip("Games within reach that aren't your backlog — a browsable "
                                       + "shelf that never counts in your library, stats or ranking. "
                                       + "Add the ones you want.")
                    }
                }
            }

            if !platformGroups.isEmpty {
                Section("Platforms") {
                    ForEach(platformGroups) { group in
                        DisclosureGroup {
                            ForEach(group.platforms) { platform in
                                taggedRow(.platform(platform.id)) {
                                    HStack {
                                        Text(platform.name)
                                        Spacer(minLength: 4)
                                    }
                                    .badge(badge(for: .platform(platform.id)))
                                }
                            }
                        } label: {
                            Label(group.name,
                                  systemImage: SidebarPlatformGrouping.icon(for: group.name))
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("VGN")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let enrichment {
                    EnrichmentStatusFooter(model: enrichment)
                }
                SidebarStatsBar(vm: vm)
            }
        }
    }

    // MARK: "By Length" section (PLAN §8)

    /// Five smart lists grouping games by their time-to-beat *estimate* (never the
    /// owner's playtime — see ``LengthShelf``), placed after RANKINGS and before
    /// PLATFORMS. Shelves stay visible when empty (dimmed); the "Unmeasured" catch-all
    /// shows only when it has games. The header carries the weekly-play-pace control.
    @ViewBuilder
    private var lengthSection: some View {
        Section {
            ForEach(SidebarSelection.lengthShelves) { sel in
                if case .length(let shelf) = sel {
                    taggedRow(sel) { lengthRow(shelf) }
                        .appKitTooltip(shelf.tooltip(pace: vm.playPace, bounds: lengthBounds))
                }
            }
            if (vm.counts.count(for: .unmeasured) ?? 0) > 0 {
                taggedRow(.unmeasured) {
                    Label(LengthShelf.unmeasuredName, systemImage: LengthShelf.unmeasuredSymbol)
                        .badge(badge(for: .unmeasured))
                }
                .appKitTooltip(LengthShelf.unmeasuredTooltip)
            }
        } header: {
            HStack {
                Text(LengthShelf.sectionHeader)
                    .appKitTooltip(vm.paceModel.styleTooltip)
                Spacer(minLength: 4)
                // Only the pace ("6 h / week") — the play style got too long in the title and
                // now lives in the popover + tooltip (owner request, wave 17).
                PaceHeaderButton(label: vm.paceModel.headerLabel,
                                 isCTA: !vm.hasChosenPace) {
                    showPacePopover = true
                }
            }
            .popover(isPresented: $showPacePopover, arrowEdge: .trailing) {
                PaceEditor(model: vm.paceModel)
                    .padding(16)
                    .frame(width: 300)
            }
        }
    }

    /// One shelf row: symbol · literary name · the hours as caption · live count.
    /// Empty shelves stay visible but dimmed (the vocabulary is fixed, unlike platforms).
    private func lengthRow(_ shelf: LengthShelf) -> some View {
        let count = vm.counts.count(for: .length(shelf)) ?? 0
        return Label {
            // Baseline-aligned: a caption centred against the larger name floats too high.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(shelf.name)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(shelf.subtitle(bounds: lengthBounds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: shelf.symbol)
        }
        .badge(badge(for: .length(shelf)))
        .opacity(count == 0 ? 0.45 : 1)
    }

    /// The single choke point where a row is tagged. The tag is always exactly
    /// `SidebarSelection`, never `SidebarSelection?` or anything else.
    private func taggedRow<Content: View>(
        _ selection: SidebarSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .tag(selection)
            // Stable identifier for the UI smoke suite, e.g. `sidebar.row.all`,
            // `sidebar.row.duel`, `sidebar.row.platform.ps4` (docs/uitests.md).
            .accessibilityIdentifier(
                A11yID.sidebarRow(selection.id.replacingOccurrences(of: ":", with: "."))
            )
    }

    /// Badge `Text` for a row, or nil to show no badge (Tier Board / The Top).
    private func badge(for selection: SidebarSelection) -> Text? {
        guard let count = vm.counts.count(for: selection) else { return nil }
        return Text(count.formatted())
    }

    // MARK: Labels & icons

    nonisolated static func title(for selection: SidebarSelection) -> String {
        switch selection {
        case .all: return "All"
        case .owned: return "Owned"
        case .played: return "Played"
        case .backlog: return "Backlog"
        case .unranked: return "Unranked"
        case .playNext: return "Play Next"
        case .unlinked: return "Unlinked"
        case .bundlesToExpand: return "Bundles to Expand"
        case .dlcAndExpansions: return "DLC & Expansions"
        case .sameGameTwoEntries: return "Same Game, Two Entries"
        case .needsHoldsUpRating: return "Needs a \u{201C}Holds Up\u{201D} Rating"
        case .tierBoard: return "Tier Board"
        case .theTop: return "The Top"
        case .duel: return "Duel"
        case .length(let shelf): return shelf.name
        case .unmeasured: return LengthShelf.unmeasuredName
        case .vault(let source): return source.rowTitle
        case .platform(let slug): return PlatformLabels.info(slug)?.name ?? slug
        }
    }

    nonisolated static func icon(for selection: SidebarSelection) -> String {
        switch selection {
        case .all: return "square.grid.2x2"
        case .owned: return "shippingbox"
        case .played: return "gamecontroller"
        case .backlog: return "tray.full"
        case .unranked: return "questionmark.circle"
        case .playNext: return "sparkles"
        case .unlinked: return "link.badge.plus"
        case .bundlesToExpand: return "square.stack.3d.up.fill"
        case .dlcAndExpansions: return "puzzlepiece.extension"
        case .sameGameTwoEntries: return "arrow.triangle.merge"
        case .needsHoldsUpRating: return "clock.badge.questionmark"
        case .tierBoard: return "square.stack.3d.up"
        case .theTop: return "trophy"
        case .duel: return "flag.2.crossed"
        case .length(let shelf): return shelf.symbol
        case .unmeasured: return LengthShelf.unmeasuredSymbol
        case .vault(let source): return source.icon
        case .platform: return "gamecontroller"
        }
    }
}

#if DEBUG
#Preview("Sidebar") {
    let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.large)
    NavigationSplitView {
        SidebarView(vm: vm)
            .task { vm.start() }
    } detail: {
        Text("Detail")
    }
    .frame(width: 720, height: 520)
}
#endif
