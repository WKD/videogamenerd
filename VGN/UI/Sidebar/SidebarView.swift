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
                Spacer(minLength: 4)
                PaceHeaderButton(label: vm.paceModel.headerLabel, isCTA: !vm.hasChosenPace) {
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
            HStack(spacing: 6) {
                Text(shelf.name)
                Text(shelf.subtitle(bounds: lengthBounds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    static func title(for selection: SidebarSelection) -> String {
        switch selection {
        case .all: return "All"
        case .owned: return "Owned"
        case .played: return "Played"
        case .backlog: return "Backlog"
        case .unranked: return "Unranked"
        case .playNext: return "Play Next"
        case .tierBoard: return "Tier Board"
        case .theTop: return "The Top"
        case .duel: return "Duel"
        case .length(let shelf): return shelf.name
        case .unmeasured: return LengthShelf.unmeasuredName
        case .platform(let slug): return PlatformLabels.info(slug)?.name ?? slug
        }
    }

    static func icon(for selection: SidebarSelection) -> String {
        switch selection {
        case .all: return "square.grid.2x2"
        case .owned: return "shippingbox"
        case .played: return "gamecontroller"
        case .backlog: return "tray.full"
        case .unranked: return "questionmark.circle"
        case .playNext: return "sparkles"
        case .tierBoard: return "square.stack.3d.up"
        case .theTop: return "trophy"
        case .duel: return "flag.2.crossed"
        case .length(let shelf): return shelf.symbol
        case .unmeasured: return LengthShelf.unmeasuredSymbol
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
