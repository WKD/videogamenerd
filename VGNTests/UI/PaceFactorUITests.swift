import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VGN

/// A data source that reports a fixed measured pace factor and records the factor the counts
/// observation was (re)subscribed with.
private final class PaceSpyDataSource: LibraryDataSource, @unchecked Sendable {
    let base: PreviewLibraryDataSource
    let measured: PaceFactor
    private let lock = NSLock()
    private var _factors: [PaceProfile] = []
    var countFactors: [PaceProfile] { lock.withLock { _factors } }
    init(_ base: PreviewLibraryDataSource, measured: PaceFactor) { self.base = base; self.measured = measured }

    func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> {
        base.sidebarCounts(pace: pace, style: style)
    }
    func sidebarCounts(pace: PlayPace, style: PlayStyle, paceFactor: PaceProfile) -> AsyncStream<SidebarCounts> {
        lock.withLock { _factors.append(paceFactor) }
        return base.sidebarCounts(pace: pace, style: style)
    }
    func paceFactorStream() -> AsyncStream<PaceFactor> { onceStream(measured) }
    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> { base.games(filter: filter) }
    func platformsInUse() -> AsyncStream<[PlatformInfo]> { base.platformsInUse() }
    func tiers() -> AsyncStream<[TierInfo]> { base.tiers() }
    func genresInUse() -> AsyncStream<[String]> { base.genresInUse() }
    func decadesInUse() -> AsyncStream<[Int]> { base.decadesInUse() }
    func gameDetail(id: Int64) async -> GameDetail? { await base.gameDetail(id: id) }
    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> { base.gameDetailStream(id: id) }
}

/// Wave 22 UI-side wiring of the personal pace factor (PLAN §7b "Scheduled 2026-09-25"): the
/// library view model adopts a measurement / override like a style change (grid + counts
/// re-run with the factor), Play Next re-plans with it, and the inspector's "for you" line
/// is one bounded line that fits the 300 pt column.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaceFactorUITests {

    private func poll(_ cond: () -> Bool) async {
        for _ in 0..<2000 where !cond() { await Task.yield() }
    }

    @Test func libraryAdoptsTheMeasuredFactorAndTheOverride() async {
        let games = (1...3).map { GameSummary(id: Int64($0), title: "G\($0)", owned: true, platformIDs: ["pc"]) }
        let spy = PaceSpyDataSource(PreviewLibraryDataSource(games: games),
                                    measured: PaceFactor(measured: 1.3, sampleCount: 109, rawMedian: 1.3))
        let prefs = InMemoryPlayPacePreferences()
        let vm = LibraryViewModel(dataSource: spy, sortPreferences: InMemorySortPreferences(),
                                  playPacePreferences: prefs)
        #expect(vm.filter.paceFactor == 1.0)
        vm.start()
        await poll { vm.filter.paceFactor == 1.3 }
        #expect(vm.filter.paceFactor == 1.3)
        await poll { spy.countFactors.last == 1.3 }
        #expect(spy.countFactors.last == 1.3)
        // The override (Settings) wins and re-runs the counts once more.
        vm.paceModel.commitPaceOverride(1.8)
        #expect(vm.filter.paceFactor == 1.8)
        await poll { spy.countFactors.last == 1.8 }
        #expect(spy.countFactors.last == 1.8)
        #expect(prefs.paceFactorOverride() == 1.8)
        vm.stop()
    }

    @Test func playNextPlansWithTheFactor() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult())
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: UserDefaults(suiteName: "pace.test.\(UUID().uuidString)")!,
                                  paceFactor: 1.3, recomputeDebounce: .milliseconds(1))
        #expect(model.bracket.paceFactor == 1.3)
        await model.start()
        await poll { backend.recommendCalls.contains { $0.bracket.paceFactor == 1.3 } }
        model.setPaceFactor(1.6)
        await poll { backend.recommendCalls.last?.bracket.paceFactor == 1.6 }
        #expect(backend.recommendCalls.last?.bracket.paceFactor == 1.6)
        model.stop()
    }

    // MARK: - Inspector line

    @Test func forYouLineText() {
        let h = 3600
        // 30 h main, story first, 1.27× (uniform) → "≈ 38 h for you · your pace 1.3×".
        #expect(PlaytimeEstimatesTable.forYouLine(
            rushed: nil, main: 30 * h, completionist: nil, sourceIsHLTB: false, dismissed: false,
            style: .storyFirst, paceFactor: 1.27) == "≈ 38 h for you · your pace 1.3×")
        // Factor 1.0 → no line; no estimate → no line.
        #expect(PlaytimeEstimatesTable.forYouLine(
            rushed: nil, main: 30 * h, completionist: nil, sourceIsHLTB: false, dismissed: false,
            style: .storyFirst, paceFactor: 1.0) == nil)
        #expect(PlaytimeEstimatesTable.forYouLine(
            rushed: 5 * h, main: nil, completionist: nil, sourceIsHLTB: false, dismissed: false,
            style: .storyFirst, paceFactor: 1.5) == nil)
        // It follows the play style (30 / 90 at lots of side quests = 60 h advertised).
        #expect(PlaytimeEstimatesTable.forYouLine(
            rushed: nil, main: 30 * h, completionist: 90 * h, sourceIsHLTB: false, dismissed: false,
            style: .lotsOfSideQuests, paceFactor: 1.5) == "≈ 90 h for you · your pace 1.5×")
    }

    @Test func forYouLineNamesTheGenreBasis() {
        let h = 3600
        let profile = PaceProfile(global: 1.8, genres: [
            .init(id: 1, name: "Point-and-click", factor: PaceProfile.quantize(2.78), sampleCount: 32),
            .init(id: 2, name: "Puzzle", factor: PaceProfile.quantize(2.41), sampleCount: 58),
            .init(id: 3, name: "Role-playing (RPG)", factor: PaceProfile.quantize(1.6), sampleCount: 25),
        ])
        func line(_ genres: [String]) -> String? {
            PlaytimeEstimatesTable.forYouLine(
                rushed: nil, main: 10 * h, completionist: nil, sourceIsHLTB: false, dismissed: false,
                style: .storyFirst, paceFactor: profile, genres: genres)
        }
        #expect(line(["Point-and-click", "Adventure"]) == "≈ 28 h for you · point-and-click pace 2.8×")
        #expect(line(["Role-playing (RPG)"]) == "≈ 16 h for you · RPG pace 1.6×")
        #expect(line(["Adventure"]) == "≈ 18 h for you · your pace 1.8×")
        #expect(line([]) == "≈ 18 h for you · your pace 1.8×")
        // Two qualifying genres: their mean, both named.
        #expect(line(["Puzzle", "Point-and-click"]) == "≈ 26 h for you · point-and-click + puzzle pace 2.6×")
        // The override replaces everything: "your pace".
        #expect(PlaytimeEstimatesTable.forYouLine(
            rushed: nil, main: 10 * h, completionist: nil, sourceIsHLTB: false, dismissed: false,
            style: .storyFirst, paceFactor: .uniform(1.5), genres: ["Point-and-click"])
                == "≈ 15 h for you · your pace 1.5×")
    }

    @Test func forYouLineFitsTheMinimumColumn() {
        func height(_ factor: PaceProfile, genres: [String] = [], width: CGFloat) -> CGFloat {
            let table = PlaytimeEstimatesTable(
                psnSeconds: 2310 * 3600, manualWins: false,
                mainS: 620 * 3600, completionistS: 1240 * 3600, rushedS: 410 * 3600,
                sourceLabel: "HowLongToBeat", showEstimates: true,
                playStyle: .lotsOfSideQuests, paceFactor: factor, genres: genres)
            let host = NSHostingView(rootView: table.frame(width: width))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        let narrow = height(1.9, width: 300 - 32)
        let wide = height(1.9, width: 440 - 32)
        #expect(narrow == wide, "for-you line wrapped: \(narrow) vs \(wide)")
        #expect(height(1.9, width: 300 - 32) > height(1.0, width: 300 - 32))   // the line is there
        // The longest basis label (a two-genre mix at the 24-character cap) stays on one line too.
        let mix = PaceProfile(global: 1.8, genres: [
            .init(id: 1, name: "Point-and-click", factor: 1.875, sampleCount: 32),
            .init(id: 2, name: "Adventure", factor: 1.9375, sampleCount: 98)])
        let mixGenres = ["Point-and-click", "Adventure"]
        #expect(height(mix, genres: mixGenres, width: 300 - 32) == height(mix, genres: mixGenres, width: 440 - 32))
    }
}
