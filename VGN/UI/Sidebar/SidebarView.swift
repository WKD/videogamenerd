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

    private var platformGroups: [SidebarPlatformGrouping.Group] {
        SidebarPlatformGrouping.groups(platforms: vm.platforms, counts: vm.counts)
    }

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
            if let enrichment {
                EnrichmentStatusFooter(model: enrichment)
            }
        }
    }

    /// The single choke point where a row is tagged. The tag is always exactly
    /// `SidebarSelection`, never `SidebarSelection?` or anything else.
    private func taggedRow<Content: View>(
        _ selection: SidebarSelection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content().tag(selection)
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
        case .tierBoard: return "Tier Board"
        case .theTop: return "The Top"
        case .duel: return "Duel"
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
        case .tierBoard: return "square.stack.3d.up"
        case .theTop: return "trophy"
        case .duel: return "flag.2.crossed"
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
