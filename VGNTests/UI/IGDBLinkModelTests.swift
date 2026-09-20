import Foundation
import Testing
@testable import VGN

/// Records the platform constraint each search was run with, and can fail on demand,
/// so the link model's debounce / platform toggle / states are testable. No network.
private actor RecordingSearcher: CatalogSearching {
    var results: [IGDBSearchResult]
    var credentials: Bool
    var fails: Bool
    private(set) var lastPlatforms: [Int]?
    private(set) var calls = 0

    init(results: [IGDBSearchResult] = [], credentials: Bool = true, fails: Bool = false) {
        self.results = results; self.credentials = credentials; self.fails = fails
    }
    func search(_ text: String, platformIGDBIDs: [Int]?, limit: Int) async throws -> [IGDBSearchResult] {
        calls += 1
        lastPlatforms = platformIGDBIDs
        if !credentials { throw IGDBError.missingCredentials }
        if fails { throw NSError(domain: "test", code: 1) }
        return results
    }
    func bundleMembers(bundleIGDBID: Int64) async throws -> BundleMemberResult { BundleMemberResult() }
    func hasCredentials() async -> Bool { credentials }
    func platformsSeen() -> [Int]? { lastPlatforms }
    func callCount() -> Int { calls }
}

@MainActor
struct IGDBLinkModelTests {

    private func result(_ id: Int64, _ name: String, year: Int? = nil, bundle: Bool = false,
                        platforms: [String] = []) -> IGDBSearchResult {
        IGDBSearchResult(id: id, name: name, releaseYear: year, coverImageID: nil,
                         platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: platforms,
                         genres: [], alternativeNames: [],
                         gameType: bundle ? .bundle : .mainGame)
    }

    private func makeModel(
        searcher: any CatalogSearching, prefill: String = "mario",
        platformIGDBIDs: [Int] = [], libraryIndex: [Int64: Int64] = [:], gameID: Int64 = 1
    ) -> IGDBLinkModel {
        IGDBLinkModel(
            gameID: gameID, currentTitle: "Old Title", platformSlugs: platformIGDBIDs.isEmpty ? [] : ["snes"],
            year: 2000, isLinked: false, prefill: prefill, searcher: searcher,
            platformIGDBIDs: platformIGDBIDs, libraryIndex: libraryIndex,
            sleep: { _ in })   // no debounce delay in tests
    }

    /// Await until `condition` holds (bounded) — a hard timeout instead of a hang.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 { if condition() { return }; await Task.yield() }
    }

    @Test func choosingAPortResultCarriesTheParentForRedirection() async {
        let model = makeModel(searcher: RecordingSearcher())
        var captured: IGDBLinkChoice?
        model.onChoose = { captured = $0 }
        let port = IGDBSearchResult(
            id: 20, name: "Super Mario Galaxy", releaseYear: 2020, coverImageID: nil,
            platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: ["switch"],
            genres: [], alternativeNames: [], gameType: .port, versionParentID: 10)
        model.choose(IGDBLinkResult(result: port, existingGameID: nil, isCurrentGame: false))
        #expect(captured?.isPort == true)          // the action layer offers "link to the original"
        #expect(captured?.portParentID == 10)
        #expect(captured?.igdbID == 20)
    }

    @Test func searchesPrefillAndPopulatesResults() async {
        let searcher = RecordingSearcher(results: [result(10, "Super Mario"), result(11, "Mario Kart")])
        let model = makeModel(searcher: searcher)
        model.start()
        await settle { model.phase == .results }
        #expect(model.results.count == 2)
        #expect(model.phase == .results)
    }

    @Test func shortQueryIsIdleAndRunsNoSearch() async {
        let searcher = RecordingSearcher(results: [result(10, "X")])
        let model = makeModel(searcher: searcher, prefill: "ab")
        model.start()
        await settle { model.phase == .idle }
        let calls = await searcher.callCount()
        #expect(model.phase == .idle)
        #expect(calls == 0)
    }

    @Test func platformToggleControlsConstraint() async {
        let searcher = RecordingSearcher(results: [result(10, "X")])
        let model = makeModel(searcher: searcher, platformIGDBIDs: [19])
        #expect(model.onlyThisPlatform)                 // on by default (game has a platform)
        model.start()
        await settle { model.phase == .results }
        let seen1 = await searcher.platformsSeen()
        #expect(seen1 == [19])

        model.onlyThisPlatform = false                  // search all platforms → re-run
        var seen2 = await searcher.platformsSeen()
        for _ in 0..<500 {
            seen2 = await searcher.platformsSeen()
            if seen2 == nil { break }
            await Task.yield()
        }
        #expect(seen2 == nil)
    }

    @Test func alreadyInLibraryMarkerAndMergeRouting() async {
        // igdb 10 belongs to a different library game (99) → merge; igdb 11 is unlinked.
        let searcher = RecordingSearcher(results: [result(10, "A"), result(11, "B")])
        let model = makeModel(searcher: searcher, libraryIndex: [10: 99], gameID: 1)
        model.start()
        await settle { model.phase == .results }
        #expect(model.results[0].alreadyInLibrary)
        #expect(!model.results[1].alreadyInLibrary)

        var choice: IGDBLinkChoice?
        model.onChoose = { choice = $0 }
        model.choose(model.results[0])
        #expect(choice?.existingGameID == 99)           // routes to merge
        choice = nil
        model.choose(model.results[1])
        #expect(choice?.existingGameID == nil)          // plain link
        #expect(choice?.igdbID == 11)
    }

    @Test func choosingOwnCurrentLinkCancels() async {
        let searcher = RecordingSearcher(results: [result(10, "A")])
        // The current game (id 1) already holds igdb 10.
        let model = makeModel(searcher: searcher, libraryIndex: [10: 1], gameID: 1)
        model.start()
        await settle { model.phase == .results }
        #expect(!model.results[0].alreadyInLibrary)     // it IS the current game
        var cancelled = false
        var chose = false
        model.onCancel = { cancelled = true }
        model.onChoose = { _ in chose = true }
        model.choose(model.results[0])
        #expect(cancelled)
        #expect(!chose)
    }

    @Test func bundleIsChoosableAndExpands() async {
        // PLAN §5.1 (2026-09-20): a bundle is now a valid choice — it triggers the expand
        // flow rather than being disabled ("how do I import Evolution Worlds then?").
        let searcher = RecordingSearcher(results: [result(10, "Collection", bundle: true)])
        let model = makeModel(searcher: searcher)
        model.start()
        await settle { model.phase == .results }
        #expect(model.results[0].isBundle)
        #expect(model.results[0].isChoosable)
        var choice: IGDBLinkChoice?
        model.onChoose = { choice = $0 }
        model.choose(model.results[0])
        #expect(choice?.isBundle == true)
        #expect(choice?.igdbID == 10)
    }

    @Test func notConfiguredState() async {
        let searcher = RecordingSearcher(credentials: false)
        let model = makeModel(searcher: searcher)
        model.start()
        await settle { model.phase == .notConfigured }
        #expect(model.phase == .notConfigured)
    }

    @Test func emptyAndErrorStates() async {
        let empty = makeModel(searcher: RecordingSearcher(results: []))
        empty.start()
        await settle { empty.phase == .empty }
        #expect(empty.phase == .empty)

        let failing = makeModel(searcher: RecordingSearcher(fails: true))
        failing.start()
        await settle { failing.phase == .error }
        #expect(failing.phase == .error)
    }

    @Test func keyboardSelectionMovesWithinBounds() async {
        let searcher = RecordingSearcher(results: [result(1, "A"), result(2, "B"), result(3, "C")])
        let model = makeModel(searcher: searcher)
        model.start()
        await settle { model.phase == .results }
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 0)               // clamped
        model.moveSelection(by: 2)
        #expect(model.selectedIndex == 2)
        model.moveSelection(by: 5)
        #expect(model.selectedIndex == 2)               // clamped to last
    }
}
