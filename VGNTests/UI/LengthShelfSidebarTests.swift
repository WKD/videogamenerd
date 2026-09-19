import Foundation
import Testing
@testable import VGN

/// A data source that counts how many times the grid and counts observations are
/// (re)subscribed, so "a pace change is exactly one restart" is testable.
private final class RestartSpyDataSource: LibraryDataSource, @unchecked Sendable {
    let base: PreviewLibraryDataSource
    private let lock = NSLock()
    private var _games = 0
    private var _counts = 0
    var gamesCalls: Int { lock.withLock { _games } }
    var countsCalls: Int { lock.withLock { _counts } }
    init(_ base: PreviewLibraryDataSource) { self.base = base }

    func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> {
        lock.withLock { _counts += 1 }; return base.sidebarCounts(pace: pace, style: style)
    }
    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> {
        lock.withLock { _games += 1 }; return base.games(filter: filter)
    }
    func platformsInUse() -> AsyncStream<[PlatformInfo]> { base.platformsInUse() }
    func tiers() -> AsyncStream<[TierInfo]> { base.tiers() }
    func genresInUse() -> AsyncStream<[String]> { base.genresInUse() }
    func decadesInUse() -> AsyncStream<[Int]> { base.decadesInUse() }
    func gameDetail(id: Int64) async -> GameDetail? { await base.gameDetail(id: id) }
    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> { base.gameDetailStream(id: id) }
}

@MainActor
struct LengthShelfSidebarTests {

    private func games(_ n: Int) -> [GameSummary] {
        (1...n).map { GameSummary(id: Int64($0), title: "G\($0)", played: true, owned: true, platformIDs: ["pc"]) }
    }

    private func makeVM(
        _ games: [GameSummary],
        sort: any SortPreferenceStoring = InMemorySortPreferences(),
        pace: any PlayPacePreferenceStoring = InMemoryPlayPacePreferences(),
        dataSource: (any LibraryDataSource)? = nil
    ) async -> LibraryViewModel {
        let vm = LibraryViewModel(
            dataSource: dataSource ?? PreviewLibraryDataSource(games: games),
            sortPreferences: sort, playPacePreferences: pace)
        vm.start()
        for _ in 0..<200 where vm.games.isEmpty && dataSource == nil { await Task.yield() }
        return vm
    }

    // MARK: - Selecting a length scope

    @Test func selectLengthScopeClearsSelectionSetsTitleAndDefaultSort() async {
        let vm = await makeVM(games(3))
        vm.selectOnly(2)
        vm.select(.length(.evening))
        #expect(vm.selection == .length(.evening))
        #expect(vm.selectedGameIDs.isEmpty)
        #expect(vm.filter.scope == .length(.evening))
        #expect(vm.filter.sort == .length)          // default for By Length scopes
        #expect(vm.filter.ascending == true)         // shortest first
        #expect(SidebarView.title(for: .length(.evening)) == "One Evening")
        #expect(!vm.isRankingSelection && !vm.isPlayNextSelection)   // a grid scope
        #expect(vm.isLibraryGridDestination)

        vm.select(.unmeasured)
        #expect(vm.selection == .unmeasured)
        #expect(SidebarView.title(for: .unmeasured) == "Unmeasured")
        #expect(vm.filter.sort == .length)
    }

    @Test func lengthScopeSortPersistsPerSelection() async {
        let sort = InMemorySortPreferences()
        let vm = await makeVM(games(3), sort: sort)
        vm.select(.length(.epic))
        #expect(vm.filter.sort == .length)   // default
        vm.setSort(.year)                     // change + persist
        #expect(vm.filter.sort == .year)

        let vm2 = await makeVM(games(3), sort: sort)
        vm2.select(.length(.epic))
        #expect(vm2.filter.sort == .year)     // restored
        vm2.select(.length(.evening))
        #expect(vm2.filter.sort == .length)   // a different shelf still defaults to Length
    }

    // MARK: - Counts drive dimming + the Unmeasured row's visibility

    @Test func countsDriveDimAndUnmeasuredVisibility() {
        var counts = SidebarCounts(all: 5, lengthShelves: [.evening: 0, .epic: 3], unmeasured: 0)
        #expect(counts.count(for: .length(.evening)) == 0)   // shown but dimmed (view opacity)
        #expect(counts.count(for: .length(.epic)) == 3)
        #expect(counts.count(for: .length(.season)) == 0)    // missing key reads as 0, still visible
        #expect((counts.count(for: .unmeasured) ?? 0) == 0)  // Unmeasured row hidden
        counts.unmeasured = 2
        #expect((counts.count(for: .unmeasured) ?? 0) > 0)   // now shown
    }

    // MARK: - Pace change: one restart, selection preserved, counts re-subscribed

    @Test func paceChangeIsExactlyOneRestartAndPreservesSelection() async {
        let spy = RestartSpyDataSource(PreviewLibraryDataSource(games: games(3)))
        let vm = await makeVM(games(3), dataSource: spy)
        for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
        vm.selectOnly(2)
        let gBefore = spy.gamesCalls, cBefore = spy.countsCalls

        // The real path: committing the pace (sidebar popover / Settings) → applyPace.
        vm.paceModel.commit(hoursPerWeek: 2)
        for _ in 0..<200 where spy.gamesCalls == gBefore { await Task.yield() }

        #expect(spy.gamesCalls == gBefore + 1)     // exactly one grid restart
        #expect(spy.countsCalls == cBefore + 1)    // exactly one counts re-subscribe
        #expect(vm.selectedGameIDs == [2])          // selection preserved
        #expect(vm.filter.playPace == PlayPace(hoursPerWeek: 2))
        #expect(vm.playPace == PlayPace(hoursPerWeek: 2))

        // A redundant pace change is ignored (no loop / no extra restart).
        let f0 = vm.filter
        let g0 = spy.gamesCalls
        vm.paceModel.commit(hoursPerWeek: 2)
        #expect(vm.filter == f0)
        #expect(spy.gamesCalls == g0)
    }

    // MARK: - Play style change: one restart, like a pace change

    @Test func styleChangeIsExactlyOneRestart() async {
        let spy = RestartSpyDataSource(PreviewLibraryDataSource(games: games(3)))
        let vm = await makeVM(games(3), dataSource: spy)
        for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
        let gBefore = spy.gamesCalls, cBefore = spy.countsCalls

        // Committing the style (sidebar popover / Settings) → applyStyle.
        vm.paceModel.commitStyle(.completionist)
        for _ in 0..<200 where spy.gamesCalls == gBefore { await Task.yield() }

        #expect(spy.gamesCalls == gBefore + 1)     // exactly one grid restart
        #expect(spy.countsCalls == cBefore + 1)    // exactly one counts re-subscribe
        #expect(vm.filter.playStyle == .completionist)

        // A redundant style change is ignored (no loop / no extra restart).
        let g0 = spy.gamesCalls
        vm.paceModel.commitStyle(.completionist)
        #expect(spy.gamesCalls == g0)
    }

    @Test func stylePersistenceRoundTripsAndShares() {
        let store = InMemoryPlayPacePreferences()
        #expect(store.playStyle() == .default)      // lots of side quests (the owner)

        let m = PlayPaceModel(store: store)
        #expect(m.style == .default)
        m.commitStyle(.storyFirst)
        #expect(store.playStyle() == .storyFirst)

        // A second model over the same store sees it on reload (Settings ↔ sidebar).
        let m2 = PlayPaceModel(store: store)
        #expect(m2.style == .storyFirst)
    }

    @Test func headerLabelWithStyleFitsThePace() {
        let m = PlayPaceModel(store: InMemoryPlayPacePreferences(pace: PlayPace(hoursPerWeek: 8),
                                                                chosen: true, style: .lotsOfSideQuests))
        #expect(m.headerLabelWithStyle == "8 h / week · lots of side quests")
    }

    // MARK: - Persistence + first-use flag; Settings and sidebar share the store

    @Test func pacePersistenceAndFirstUseFlag() {
        let store = InMemoryPlayPacePreferences()
        #expect(store.hasChosenPace() == false)
        #expect(store.playPace() == .default)

        let m = PlayPaceModel(store: store)
        #expect(m.hasChosen == false)
        #expect(m.headerLabel == "Set your pace…")   // first-use call to action
        m.commit(hoursPerWeek: 5)
        #expect(store.hasChosenPace())
        #expect(store.playPace() == PlayPace(hoursPerWeek: 5))
        #expect(m.headerLabel == "5 h / week")
        m.reset()
        #expect(m.pace == .default)
        #expect(m.headerLabel == "8 h / week")
    }

    @Test func settingsAndSidebarShareTheSameStore() {
        let store = InMemoryPlayPacePreferences()
        let sidebar = PlayPaceModel(store: store)   // the sidebar header popover
        let settings = PlayPaceModel(store: store)  // Settings ▸ General

        sidebar.commit(hoursPerWeek: 3)
        settings.reload()
        #expect(settings.pace == PlayPace(hoursPerWeek: 3))
        #expect(settings.hasChosen)

        settings.commit(hoursPerWeek: 20)
        sidebar.reload()
        #expect(sidebar.pace == PlayPace(hoursPerWeek: 20))
    }

    @Test func userDefaultsPaceRoundTripsAndNeverUsesStandard() {
        let name = "vgn-pace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsPlayPacePreferences(defaults: defaults)
        #expect(store.playPace() == .default)
        #expect(!store.hasChosenPace())
        store.setPlayPace(PlayPace(hoursPerWeek: 12))
        #expect(store.hasChosenPace())
        // A fresh store over the same suite reads it back (relaunch).
        let store2 = UserDefaultsPlayPacePreferences(defaults: defaults)
        #expect(store2.playPace() == PlayPace(hoursPerWeek: 12))
    }
}
