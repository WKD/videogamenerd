import SwiftUI

/// Stable identifier of the Library Stats scene (`Window(id:)` in ``VGNApp``).
enum StatsWindowID {
    static let id = "library-stats"
}

/// The root of the Library Stats window. Owns the ``StatsModel`` for the window's
/// lifetime (so reopening the window keeps a fresh model), starts it when shown and
/// stops observing when the window closes. Built from a ``LibraryStatsStore`` handed
/// in by the composition root, so it works in every `LaunchMode` (live / sample /
/// seeded) — whichever database ``AppEnvironment`` opened.
struct StatsWindowRoot: View {
    @State private var model: StatsModel

    init(store: LibraryStatsStore) {
        _model = State(initialValue: StatsModel(store: store))
    }

    var body: some View {
        StatsDashboardView(model: model)
            .task { await model.start() }
            .onDisappear { model.stop() }
    }
}

/// Shown by the window when no database is open (the XCTest host, or a failed
/// launch). The real app always has one in live/sample/seeded modes.
struct StatsUnavailableView: View {
    var body: some View {
        ContentUnavailableView(
            "Stats Unavailable",
            systemImage: "chart.bar.xaxis",
            description: Text("Open your library to see its statistics.")
        )
        .frame(minWidth: 420, minHeight: 300)
    }
}

#if DEBUG
extension LibraryStatsReport {
    /// A representative report for previews and snapshot tests.
    static var sample: LibraryStatsReport {
        let h = 3600
        return LibraryStatsReport(
            scope: .all, referenceDate: Date(timeIntervalSince1970: 1_760_000_000),
            totalGames: 812, ownedGames: 540, playedGames: 655, backlogGames: 157,
            playedNotOwned: 115, compilations: 24,
            copiesByFormat: [.init(format: .physical, count: 320),
                             .init(format: .digital, count: 260),
                             .init(format: .rom, count: 40)],
            totalPlaytimeSeconds: 1_240 * h,
            playtimeByPlatform: [.init(platformID: "ps4", seconds: 420 * h),
                                 .init(platformID: "ps2", seconds: 300 * h),
                                 .init(platformID: "pc", seconds: 260 * h),
                                 .init(platformID: "snes", seconds: 140 * h),
                                 .init(platformID: "ps5", seconds: 120 * h)],
            playtimeByDecade: [.init(decade: 1990, seconds: 210 * h),
                               .init(decade: 2000, seconds: 480 * h),
                               .init(decade: 2010, seconds: 400 * h),
                               .init(decade: 2020, seconds: 150 * h)],
            playtimeByTier: [.init(tierID: 1, letter: "S", colorHex: "#FF7F7F", seconds: 300 * h),
                             .init(tierID: 2, letter: "A", colorHex: "#FFBF7F", seconds: 420 * h),
                             .init(tierID: 3, letter: "B", colorHex: "#FFDF7F", seconds: 300 * h)],
            topPlayed: [.init(gameID: 1, title: "Persona 5 Royal", seconds: 120 * h),
                        .init(gameID: 2, title: "The Witcher 3", seconds: 96 * h),
                        .init(gameID: 3, title: "Elden Ring", seconds: 88 * h),
                        .init(gameID: 4, title: "Final Fantasy XII", seconds: 70 * h),
                        .init(gameID: 5, title: "Bloodborne", seconds: 62 * h)],
            myHoursVsAverage: .init(mineSeconds: 5_400 * h, averageSeconds: 4_100 * h, gameCount: 210,
                                    backlogEstimateSeconds: 2_200 * h, backlogGamesMissingEstimate: 38),
            platformBreakdown: [.init(platformID: "ps5", total: 62, owned: 60, played: 40),
                                .init(platformID: "ps4", total: 210, owned: 190, played: 170),
                                .init(platformID: "ps2", total: 140, owned: 120, played: 120),
                                .init(platformID: "snes", total: 80, owned: 55, played: 70),
                                .init(platformID: "pc", total: 120, owned: 118, played: 95)],
            gamesByDecade: [.init(decade: 1990, count: 120), .init(decade: 2000, count: 280),
                            .init(decade: 2010, count: 300), .init(decade: 2020, count: 100),
                            .init(decade: nil, count: 12)],
            gamesByYear: (1995...2024).map { .init(year: $0, count: 8 + ($0 % 7) * 3) },
            unknownYearCount: 12,
            tierBreakdown: [.init(tierID: 1, letter: "S", label: "Masterpiece", colorHex: "#FF7F7F", sort: 0, count: 20),
                            .init(tierID: 2, letter: "A", label: "Excellent", colorHex: "#FFBF7F", sort: 1, count: 55),
                            .init(tierID: 3, letter: "B", label: "Good", colorHex: "#FFDF7F", sort: 2, count: 120),
                            .init(tierID: 4, letter: "C", label: "Average", colorHex: "#FFFF7F", sort: 3, count: 90),
                            .init(tierID: 5, letter: "D", label: "Bad", colorHex: "#BFFF7F", sort: 4, count: 30),
                            .init(tierID: 6, letter: "F", label: "Awful", colorHex: "#7FFF7F", sort: 5, count: 8)],
            unrankedPlayedCount: 43,
            averageScoreByPlatform: [.init(platformID: "ps4", average: 7.8, n: 120),
                                     .init(platformID: "snes", average: 8.4, n: 40),
                                     .init(platformID: "pc", average: 7.2, n: 80)],
            averageScoreByDecade: [.init(decade: 1990, average: 8.1, n: 60),
                                   .init(decade: 2000, average: 7.6, n: 140),
                                   .init(decade: 2010, average: 7.3, n: 120)],
            bestGameByPlatform: [.init(platformID: "ps4", gameID: 1, title: "Bloodborne", score: 9.8),
                                 .init(platformID: "snes", gameID: 9, title: "Chrono Trigger", score: 9.9),
                                 .init(platformID: "pc", gameID: 12, title: "Disco Elysium", score: 9.5)],
            gamesByGenre: [.init(genre: "Role-playing (RPG)", count: 180),
                           .init(genre: "Adventure", count: 120),
                           .init(genre: "Shooter", count: 90),
                           .init(genre: "Platform", count: 70),
                           .init(genre: "Strategy", count: 40)],
            averageScoreByGenre: [.init(genre: "Role-playing (RPG)", average: 8.2, n: 95),
                                  .init(genre: "Adventure", average: 7.6, n: 40),
                                  .init(genre: "Platform", average: 7.9, n: 22)],
            statusCounts: .init(playing: 12, finished: 300, completed: 90, abandoned: 45, noStatus: 208),
            completionRate: Double(300 + 90) / 655,
            addedByMonth: (1...12).map { .init(year: 2024, month: $0, count: 4 + ($0 % 5) * 6) })
    }
}

#Preview("Stats dashboard") {
    StatsDashboardView(model: StatsModel(previewReport: .sample))
        .frame(width: 900, height: 700)
}

extension StatsModel {
    /// A model pinned to a fixed report, for previews / snapshots (no observation).
    convenience init(previewReport: LibraryStatsReport) {
        // A throwaway in-memory database satisfies the store dependency; the model
        // is fed the fixed report directly and never started.
        let db = try! AppDatabase.inMemory()
        self.init(store: LibraryStatsStore(db), scope: previewReport.scope)
        self.applyPreview(previewReport)
    }
}
#endif
