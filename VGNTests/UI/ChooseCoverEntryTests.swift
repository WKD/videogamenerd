import Foundation
import CoreGraphics
import Testing
@testable import VGN

/// A cover loader that can browse candidates (so the "Choose Cover…" entry points
/// enable). No I/O — the model logic under test never fetches.
private struct BrowsableCoverLoader: CoverLoading, ChooseCoverProviding {
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> sending CGImage? { nil }
    func coverCandidates(forGameID id: Int64) async -> [CoverCandidate] { [] }
    func candidateThumbnail(for candidate: CoverCandidate, maxPixel: Int) async -> sending CGImage? { nil }
    func chooseCandidate(_ candidate: CoverCandidate, forGameID id: Int64) async throws {}
    func importCoverFile(_ url: URL, forGameID id: Int64) async throws {}
}

@MainActor
struct ChooseCoverEntryTests {

    private func loadedVM(loader: any CoverLoading) async -> LibraryViewModel {
        let games = [GameSummary(id: 1, title: "Ocarina of Time", played: true, owned: true,
                                 platformIDs: ["ps2"])]
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: games), coverLoader: loader)
        vm.start()
        for _ in 0..<200 where vm.games.isEmpty { await Task.yield() }
        return vm
    }

    @Test("A loader that can't browse disables Choose Cover and never presents it")
    func noopLoaderDisables() async {
        let vm = await loadedVM(loader: NoopCoverLoader())
        #expect(vm.canChooseCover == false)
        vm.requestChooseCover(gameID: 1)
        #expect(vm.chooseCoverRequest == nil)
    }

    @Test("A browsable loader enables Choose Cover and presents the request")
    func browsableLoaderPresents() async {
        let vm = await loadedVM(loader: BrowsableCoverLoader())
        #expect(vm.canChooseCover)
        vm.requestChooseCover(gameID: 1)
        #expect(vm.chooseCoverRequest?.id == 1)
        #expect(vm.chooseCoverRequest?.title == "Ocarina of Time")
        // onFinished clears the shared presentation.
        vm.chooseCoverRequest?.onFinished()
        #expect(vm.chooseCoverRequest == nil)
    }

    @Test("Requesting a cover for an unknown game is a no-op")
    func unknownGameNoop() async {
        let vm = await loadedVM(loader: BrowsableCoverLoader())
        vm.requestChooseCover(gameID: 999)
        #expect(vm.chooseCoverRequest == nil)
    }
}
