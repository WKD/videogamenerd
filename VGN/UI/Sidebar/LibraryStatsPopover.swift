import SwiftUI

/// A small "chart" button pinned to the sidebar footer that opens a library-stats
/// popover (PLAN §6.4): totals, hours played, top platforms and per-tier counts.
/// Cheap aggregates — not the full stats view (a later milestone).
struct SidebarStatsBar: View {
    @Bindable var vm: LibraryViewModel
    @State private var showStats = false
    @State private var stats: LibraryStats = .empty

    var body: some View {
        HStack {
            Button {
                showStats.toggle()
            } label: {
                Label("Stats", systemImage: "chart.bar.xaxis")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showStats, arrowEdge: .top) {
                LibraryStatsPopover(stats: stats, tiers: vm.tiers)
                    .task { stats = await vm.libraryStats() }
            }
            Spacer()
            Text("\(vm.counts.all) games")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The popover contents.
struct LibraryStatsPopover: View {
    let stats: LibraryStats
    var tiers: [TierInfo] = []

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var hours: Int { stats.totalPlaytimeSeconds / 3600 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Library").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                statRow("Games", stats.total)
                statRow("Owned", stats.owned)
                statRow("Played", stats.played)
                statRow("Backlog", stats.backlog)
                GridRow {
                    Text("Hours played").foregroundStyle(.secondary)
                    Text("\(hours) h").gridColumnAlignment(.trailing).monospacedDigit()
                }
            }
            .font(.callout)

            if !stats.byPlatform.isEmpty {
                Divider()
                Text("Top platforms").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(stats.byPlatform) { row in
                    HStack {
                        Text(PlatformLabels.short(row.platformID))
                        Spacer()
                        Text(row.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            let tieredRows = stats.byTier.filter { $0.count > 0 }
            if !tieredRows.isEmpty {
                Divider()
                Text("By tier").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(tieredRows) { row in
                        VStack(spacing: 2) {
                            Text(row.letter).font(.caption.bold())
                            Text(row.count.formatted()).font(.caption2).foregroundStyle(.secondary)
                        }
                        .help(TierChip.hoverText(
                            letter: row.letter,
                            label: tiers.first { $0.letter == row.letter }?.label,
                            labels: [:]))
                    }
                }
            }

            Divider()
            Button {
                dismiss()
                openWindow(id: StatsWindowID.id)
            } label: {
                Label("Show All Stats…", systemImage: "chart.bar.xaxis")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 240)
    }

    private func statRow(_ label: String, _ value: Int) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted()).gridColumnAlignment(.trailing).monospacedDigit()
        }
    }
}

#if DEBUG
#Preview("Stats popover") {
    LibraryStatsPopover(
        stats: LibraryStats(
            total: 812, owned: 540, played: 655, backlog: 157, totalPlaytimeSeconds: 1_240 * 3600,
            byPlatform: [
                .init(platformID: "ps4", count: 210), .init(platformID: "ps2", count: 140),
                .init(platformID: "pc", count: 120), .init(platformID: "snes", count: 80),
                .init(platformID: "ps5", count: 62),
            ],
            byTier: [
                .init(tierID: 1, letter: "S", count: 20), .init(tierID: 2, letter: "A", count: 55),
                .init(tierID: 3, letter: "B", count: 120), .init(tierID: 4, letter: "C", count: 90),
                .init(tierID: 5, letter: "D", count: 30), .init(tierID: 6, letter: "F", count: 8),
            ]),
        tiers: TierInfo.defaultTiers)
}
#endif
