import Foundation
import Testing
@testable import VGN

/// A data source that forwards to a `PreviewLibraryDataSource` but emits a chosen
/// derived-scores map, so the VM's `scoresByGameID` wiring can be tested directly.
private struct ScoresStubDataSource: LibraryDataSource {
    var base: PreviewLibraryDataSource
    var scores: [Int64: DerivedScoreValue]

    func sidebarCounts(pace: PlayPace) -> AsyncStream<SidebarCounts> { base.sidebarCounts(pace: pace) }
    func platformsInUse() -> AsyncStream<[PlatformInfo]> { base.platformsInUse() }
    func tiers() -> AsyncStream<[TierInfo]> { base.tiers() }
    func genresInUse() -> AsyncStream<[String]> { base.genresInUse() }
    func decadesInUse() -> AsyncStream<[Int]> { base.decadesInUse() }
    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> { base.games(filter: filter) }
    func gameDetail(id: Int64) async -> GameDetail? { await base.gameDetail(id: id) }
    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> { base.gameDetailStream(id: id) }
    func scoresStream() -> AsyncStream<[Int64: DerivedScoreValue]> { onceStream(scores) }
}

@MainActor
@Suite(.serialized)
struct LibraryViewModelScoresTests {
    @Test func scoresStreamPopulatesScoresByGameID() async throws {
        let games = [
            GameSummary(id: 1, title: "Ranked", tierID: 1, tierLetter: "S", played: true, owned: true),
            GameSummary(id: 2, title: "Untiered", played: true, owned: true),
        ]
        let scores: [Int64: DerivedScoreValue] = [1: DerivedScoreValue(value: 9.4, isApproximate: false)]
        let vm = LibraryViewModel(dataSource: ScoresStubDataSource(
            base: PreviewLibraryDataSource(games: games), scores: scores))
        vm.start()
        for _ in 0..<200 where vm.scoresByGameID.isEmpty { await Task.yield() }

        #expect(vm.scoresByGameID[1]?.value == 9.4)
        #expect(vm.scoresByGameID[1]?.isApproximate == false)
        #expect(vm.scoresByGameID[2] == nil)   // untiered ⇒ no score
        vm.stop()
    }

    @Test func defaultDataSourceLeavesScoresEmpty() async throws {
        // PreviewLibraryDataSource uses the protocol's default (empty) scoresStream.
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(
            games: [GameSummary(id: 1, title: "A", played: true, owned: true)]))
        vm.start()
        for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
        #expect(vm.scoresByGameID.isEmpty)
        vm.stop()
    }
}
