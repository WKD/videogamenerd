import Charts
import SwiftUI

/// The scrollable Library Stats dashboard (PLAN §6.4): a scope picker over an
/// adaptive grid of cards. Pure presentation of the model's ``LibraryStatsReport``
/// — it never writes observable state from `body` (scope changes flow through the
/// picker's binding, a user action).
struct StatsDashboardView: View {
    @Bindable var model: StatsModel

    private let columns = [GridItem(.adaptive(minimum: 330), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Library Stats").font(.title3.weight(.semibold))
                if !model.report.isEmpty {
                    Text("\(model.report.totalGames.formatted()) games in scope")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Scope", selection: model.scopeBinding) {
                ForEach(StatsScope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.report.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.report.isEmpty {
            EmptyStateView(
                systemImage: "chart.bar.xaxis",
                title: emptyTitle,
                message: emptyMessage,
                actions: model.scope == .all ? [] : [
                    EmptyStateAction(title: "Show all games", isProminent: true) {
                        model.scopeBinding.wrappedValue = .all
                    },
                ])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    let r = model.report
                    StatsOverviewCard(report: r)
                    StatsPlaytimeCard(report: r)
                    StatsHoursByCard(report: r)
                    StatsTopPlayedCard(report: r)
                    StatsPlatformsCard(report: r)
                    StatsDecadesCard(report: r)
                    StatsTiersCard(report: r)
                    StatsScoresCard(report: r)
                    StatsGenresCard(report: r)
                    StatsStatusCard(report: r)
                    StatsActivityCard(report: r)
                }
                .padding(20)
            }
        }
    }

    private var emptyTitle: String {
        model.scope == .all ? "No Games Yet" : "Nothing \(model.scope.label)"
    }
    private var emptyMessage: String {
        model.scope == .all
            ? "Add some games first to see your stats."
            : "No games match the \(model.scope.label.lowercased()) scope yet."
    }
}

// MARK: - 1 · Overview

private struct StatsOverviewCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Overview") {
            VStack(spacing: 6) {
                StatsMetricRow(label: "Games", value: StatsFormat.count(report.totalGames), emphasised: true)
                StatsMetricRow(label: "Owned", value: StatsFormat.count(report.ownedGames))
                StatsMetricRow(label: "Played", value: StatsFormat.count(report.playedGames))
                StatsMetricRow(label: "Backlog (owned, unplayed)", value: StatsFormat.count(report.backlogGames))
                StatsMetricRow(label: "Played but not owned", value: StatsFormat.count(report.playedNotOwned))
                StatsMetricRow(label: "Compilations", value: StatsFormat.count(report.compilations))
                if !report.copiesByFormat.isEmpty {
                    Divider().padding(.vertical, 2)
                    ForEach(report.copiesByFormat) { fc in
                        StatsMetricRow(label: "\(fc.format.label) copies", value: StatsFormat.count(fc.count))
                    }
                }
            }
        }
    }
}

// MARK: - 2 · Playtime headline (total + me vs average + backlog estimate)

private struct StatsPlaytimeCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Playtime", subtitle: "Effective hours — manual over PSN") {
            VStack(alignment: .leading, spacing: 10) {
                Text(StatsFormat.hours(report.totalPlaytimeSeconds))
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text("total across \(report.totalGames.formatted()) games")
                    .font(.caption).foregroundStyle(.secondary)

                Divider()
                let mva = report.myHoursVsAverage
                if mva.gameCount > 0 {
                    Text("Me vs. average").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    StatsHBarChart(bars: [
                        StatsBar(id: "mine", label: "Me", value: Double(mva.mineSeconds),
                                 valueText: StatsFormat.hours(mva.mineSeconds), colorHex: nil),
                        StatsBar(id: "avg", label: "IGDB main", value: Double(mva.averageSeconds),
                                 valueText: StatsFormat.hours(mva.averageSeconds), colorHex: "#8E8E93"),
                    ])
                    Text("over \(mva.gameCount.formatted()) games with both a playtime and an estimate")
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    StatsCardEmpty(text: "No games with both my playtime and an IGDB estimate.")
                }

                Divider()
                Text("Backlog to beat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                // The planning figure uses the owner's personal length (D4), so label the
                // basis — "≈ 1,240 h at your play style · 96 games, 14 without an estimate".
                StatsMetricRow(label: "At your play style",
                               value: "≈ " + StatsFormat.hours(report.myHoursVsAverage.backlogEstimateSeconds),
                               emphasised: true)
                Text(backlogBasis)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// "96 games" or "96 games, 14 without an estimate" (a rushed-only game counts as
    /// without an estimate — the personal length is undefined for it).
    private var backlogBasis: String {
        let games = "\(report.backlogGames.formatted()) games"
        let missing = report.myHoursVsAverage.backlogGamesMissingEstimate
        return missing > 0 ? "\(games), \(missing.formatted()) without an estimate" : games
    }
}

// MARK: - 2 · Hours by platform / decade / tier

private struct StatsHoursByCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Hours Played") {
            VStack(alignment: .leading, spacing: 14) {
                group("By platform", bars: report.playtimeByPlatform.prefix(10).map {
                    StatsBar(id: "p\($0.platformID)", label: PlatformLabels.short($0.platformID),
                             value: Double($0.seconds), valueText: StatsFormat.hours($0.seconds), colorHex: nil)
                })
                group("By decade", bars: report.playtimeByDecade.map {
                    StatsBar(id: "d\($0.id)", label: StatsFormat.decade($0.decade),
                             value: Double($0.seconds), valueText: StatsFormat.hours($0.seconds), colorHex: nil)
                })
                group("By tier", bars: report.playtimeByTier.map {
                    StatsBar(id: "t\($0.tierID)", label: $0.letter,
                             value: Double($0.seconds), valueText: StatsFormat.hours($0.seconds),
                             colorHex: $0.colorHex)
                })
            }
        }
    }

    @ViewBuilder private func group(_ title: String, bars: [StatsBar]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if bars.isEmpty { StatsCardEmpty(text: "No playtime recorded.") }
            else { StatsHBarChart(bars: bars) }
        }
    }
}

// MARK: - 2 · Top played

private struct StatsTopPlayedCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Most Played", subtitle: "Top \(min(report.topPlayed.count, 10))") {
            if report.topPlayed.isEmpty {
                StatsCardEmpty(text: "No playtime recorded yet.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(report.topPlayed.enumerated()), id: \.element.id) { i, g in
                        HStack(spacing: 8) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(g.title).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(StatsFormat.hours(g.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: - 3 · Platforms (grouped by manufacturer, owned vs played)

private struct StatsPlatformsCard: View {
    let report: LibraryStatsReport

    private struct Group: Identifiable { var name: String; var rows: [LibraryStatsReport.PlatformBreakdown]; var id: String { name } }

    private var groups: [Group] {
        var byGroup: [String: [LibraryStatsReport.PlatformBreakdown]] = [:]
        for row in report.platformBreakdown {
            let g = PlatformLabels.info(row.platformID)?.group ?? "Other"
            byGroup[g, default: []].append(row)
        }
        // Group order: by the smallest catalogue sort within the group, then name.
        func groupSort(_ name: String) -> Int {
            byGroup[name]?.compactMap { PlatformLabels.info($0.platformID)?.sort }.min() ?? Int.max
        }
        return byGroup.keys.sorted { groupSort($0) != groupSort($1) ? groupSort($0) < groupSort($1) : $0 < $1 }
            .map { name in
                let rows = byGroup[name]!.sorted {
                    let a = PlatformLabels.info($0.platformID)?.sort ?? Int.max
                    let b = PlatformLabels.info($1.platformID)?.sort ?? Int.max
                    return a != b ? a < b : $0.platformID < $1.platformID
                }
                return Group(name: name, rows: rows)
            }
    }

    var body: some View {
        StatsCard("Platforms", subtitle: "Games · owned / played") {
            if report.platformBreakdown.isEmpty {
                StatsCardEmpty(text: "No platforms in use yet.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(group.rows) { row in
                                HStack(spacing: 8) {
                                    Text(PlatformLabels.short(row.platformID)).frame(width: 60, alignment: .leading)
                                    Text("\(row.total)").monospacedDigit().fontWeight(.medium)
                                    Spacer(minLength: 6)
                                    Text("\(row.owned) owned · \(row.played) played")
                                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 4 · Decades & years

private struct StatsDecadesCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Decades & Years",
                  subtitle: report.unknownYearCount > 0 ? "\(report.unknownYearCount) with unknown year" : nil) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Games by decade").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    let bars = report.gamesByDecade.filter { $0.decade != nil }.map {
                        StatsBar(id: "d\($0.id)", label: StatsFormat.decade($0.decade),
                                 value: Double($0.count), valueText: "\($0.count)", colorHex: nil)
                    }
                    if bars.isEmpty { StatsCardEmpty(text: "No dated games.") }
                    else { StatsHBarChart(bars: bars) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Games by year").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if report.gamesByYear.isEmpty { StatsCardEmpty(text: "No dated games.") }
                    else {
                        StatsColumnChart(columns: report.gamesByYear.map {
                            StatsColumn(id: "y\($0.year)", label: String($0.year), value: Double($0.count), colorHex: nil)
                        })
                    }
                }
            }
        }
    }
}

// MARK: - 5a · Tiers

private struct StatsTiersCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Tiers",
                  subtitle: report.unrankedPlayedCount > 0 ? "\(report.unrankedPlayedCount) played, unranked" : nil) {
            let tiers = report.tierBreakdown
            if tiers.allSatisfy({ $0.count == 0 }) {
                StatsCardEmpty(text: "No games have been ranked yet.")
            } else {
                let bars = tiers.map {
                    StatsBar(id: "t\($0.tierID)", label: $0.letter, value: Double($0.count),
                             valueText: "\($0.count)", colorHex: $0.colorHex)
                }
                StatsHBarChart(bars: bars)
            }
        }
    }
}

// MARK: - 5b · Scores (averages + best per platform)

private struct StatsScoresCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Scores", subtitle: "Derived 1–10, ranked games only") {
            VStack(alignment: .leading, spacing: 14) {
                section("Average by platform", rows: report.averageScoreByPlatform.prefix(8).map {
                    (PlatformLabels.short($0.platformID), $0.average, $0.n)
                })
                section("Average by decade", rows: report.averageScoreByDecade.map {
                    (StatsFormat.decade($0.decade), $0.average, $0.n)
                })
                VStack(alignment: .leading, spacing: 4) {
                    Text("Best per platform").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if report.bestGameByPlatform.isEmpty {
                        StatsCardEmpty(text: "No ranked games yet.")
                    } else {
                        ForEach(report.bestGameByPlatform.prefix(8)) { best in
                            HStack(spacing: 8) {
                                Text(PlatformLabels.short(best.platformID)).frame(width: 60, alignment: .leading)
                                Text(best.title).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(StatsFormat.score(best.score)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String, rows: [(String, Double, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if rows.isEmpty {
                StatsCardEmpty(text: "No ranked games yet.")
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0)
                        Spacer(minLength: 8)
                        Text("\(StatsFormat.score(row.1))").monospacedDigit()
                        Text("· n\u{00A0}\(row.2)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - 6 · Genres

private struct StatsGenresCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Genres") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Games by genre").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if report.gamesByGenre.isEmpty {
                        StatsCardEmpty(text: "No genres recorded yet.")
                    } else {
                        StatsHBarChart(bars: report.gamesByGenre.prefix(10).map {
                            StatsBar(id: "g\($0.genre)", label: $0.genre, value: Double($0.count),
                                     valueText: "\($0.count)", colorHex: nil)
                        })
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Average score (n ≥ 3)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if report.averageScoreByGenre.isEmpty {
                        StatsCardEmpty(text: "No genre has three ranked games yet.")
                    } else {
                        ForEach(report.averageScoreByGenre.prefix(8)) { gs in
                            HStack {
                                Text(gs.genre).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(StatsFormat.score(gs.average)).monospacedDigit()
                                Text("· n\u{00A0}\(gs.n)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 7 · Status

private struct StatsStatusCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Status", subtitle: "Of played games") {
            let s = report.statusCounts
            VStack(spacing: 6) {
                StatsMetricRow(label: "Playing", value: StatsFormat.count(s.playing))
                StatsMetricRow(label: "Finished", value: StatsFormat.count(s.finished))
                StatsMetricRow(label: "100 %", value: StatsFormat.count(s.completed))
                StatsMetricRow(label: "Abandoned", value: StatsFormat.count(s.abandoned))
                StatsMetricRow(label: "To Revisit", value: StatsFormat.count(s.toRevisit))
                StatsMetricRow(label: "No status", value: StatsFormat.count(s.noStatus))
                Divider().padding(.vertical, 2)
                StatsMetricRow(label: "Completion rate",
                               value: report.completionRate.map(StatsFormat.percent) ?? "—",
                               emphasised: true)
                // "Holds up today?" (PLAN §7b) — how the played games play now.
                Divider().padding(.vertical, 2)
                Text(HoldsUpMenuItems.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let h = report.holdsUpCounts
                ForEach(HoldsUp.allCases) { value in
                    StatsMetricRow(label: value.label, value: StatsFormat.count(h.count(value)))
                }
                StatsMetricRow(label: HoldsUp.unratedLabel, value: StatsFormat.count(h.unrated))
            }
        }
    }
}

// MARK: - 8 · Activity

private struct StatsActivityCard: View {
    let report: LibraryStatsReport

    var body: some View {
        StatsCard("Activity", subtitle: "Games added, last 12 months") {
            if report.addedByMonth.allSatisfy({ $0.count == 0 }) {
                StatsCardEmpty(text: "Nothing added in the last year.")
            } else {
                StatsColumnChart(columns: report.addedByMonth.map {
                    StatsColumn(id: $0.id.description, label: $0.shortLabel, value: Double($0.count), colorHex: nil)
                }, height: 150)
            }
        }
    }
}
