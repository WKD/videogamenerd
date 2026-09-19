import Foundation
import Testing
@testable import VGN

/// Quick Add model logic (PLAN §6.1) driven entirely by fakes — no GRDB, no
/// network. `@MainActor` (the model is main-isolated); serialized and hard
/// time-limited per the repo's test rules.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QuickAddModelTests {

    // MARK: - Pure merge / defaults

    @Test func buildResultsMergesAndMarksInLibrary() {
        let catalog = [
            makeSearchResult(id: 1, name: "The Legend of Zelda", platforms: ["nes"]),
            makeSearchResult(id: 2, name: "Elden Ring", platforms: ["ps5"]),
        ]
        let local = [
            makeLibraryMatch(id: 10, title: "Legend of Zelda", platforms: ["nes"], owned: true),
            makeLibraryMatch(id: 11, title: "Halo", platforms: ["xbox"], owned: true),
        ]
        let results = QuickAddModel.buildResults(catalog: catalog, local: local)

        #expect(results[0].title == "The Legend of Zelda")
        #expect(results[0].isInLibrary)                       // matched by normalised title
        #expect(results[1].isInLibrary == false)              // Elden Ring not owned
        // Halo has no catalogue counterpart → appended as a local-only row.
        #expect(results.last?.title == "Halo")
        #expect(results.last?.source == .local)
        // The matched local game is not duplicated as a separate row.
        #expect(results.filter { $0.libraryMatch?.gameID == 10 }.count == 1)
    }

    @Test func mergeCatalogShowsCachedThenLiveReplacesSameID() {
        let cached = [makeSearchResult(id: 7334, name: "Bloodborne", year: 2015),
                      makeSearchResult(id: 42, name: "Blood Omen")]
        // Before the live response, cached rows are shown as-is.
        #expect(QuickAddModel.mergeCatalog(cached: cached, live: [], liveArrived: false, limit: 12)
            .map(\.id) == [7334, 42])
        // Live arrives: it leads and replaces the same id (7334) — no duplicate —
        // and the cached-only row (42) is appended after.
        let live = [makeSearchResult(id: 7334, name: "Bloodborne", year: 2015, platforms: ["ps4"]),
                    makeSearchResult(id: 99, name: "Bloodborne GOTY")]
        let merged = QuickAddModel.mergeCatalog(cached: cached, live: live, liveArrived: true, limit: 12)
        #expect(merged.map(\.id) == [7334, 99, 42])
        #expect(merged.filter { $0.id == 7334 }.count == 1)       // no jump/dup
        #expect(merged.first?.platformSlugs == ["ps4"])           // the LIVE 7334 row wins
        // Caps to the limit.
        #expect(QuickAddModel.mergeCatalog(cached: cached, live: live, liveArrived: true, limit: 2)
            .map(\.id) == [7334, 99])
    }

    @Test func cachedRowsSurfaceThenLiveReplacesInModel() {
        let model = makeQuickAddModel()                 // no real cache seam → drive directly
        model.query = "blood"
        let gen = model.searchGeneration
        // Instant catalogue-cache rows appear before the (debounced) live call.
        model.applyCached([makeSearchResult(id: 7334, name: "Bloodborne", year: 2015),
                           makeSearchResult(id: 42, name: "Blood Omen")], generation: gen)
        #expect(model.results.map(\.title) == ["Bloodborne", "Blood Omen"])
        #expect(model.results.allSatisfy { $0.source == .catalog })
        // Live arrives → replaces same id, cached-only appended, no dup / no jump.
        model.applyRemote([makeSearchResult(id: 7334, name: "Bloodborne", year: 2015, platforms: ["ps4"]),
                           makeSearchResult(id: 99, name: "Bloodborne GOTY")],
                          generation: gen, credentials: true)
        #expect(model.results.map(\.igdbID) == [7334, 99, 42])
        #expect(model.results.filter { $0.igdbID == 7334 }.count == 1)
    }

    @Test func defaultPlatformFollowsPlanRule() {
        let gen: @Sendable (String) -> Int? = { QuickAddTestPlatforms.generation[$0] }
        // Sidebar platform wins when the game is on it.
        #expect(QuickAddModel.defaultPlatform(
            options: ["ps4", "ps5"], sidebar: "ps4", owned: [], generation: gen) == "ps4")
        // Sidebar not among options → newest platform the user already owns games on.
        #expect(QuickAddModel.defaultPlatform(
            options: ["ps3", "ps4", "ps5"], sidebar: "snes", owned: ["ps3", "ps4"], generation: gen) == "ps4")
        // None owned → the newest overall.
        #expect(QuickAddModel.defaultPlatform(
            options: ["ps3", "ps4", "ps5"], sidebar: nil, owned: [], generation: gen) == "ps5")
    }

    @Test func platformCyclingWraps() {
        let model = makeQuickAddModel()
        let result = makeSearchResult(id: 1, name: "Cross", platforms: ["ps3", "ps4", "ps5"])
        model.query = "cross"
        model.applyRemote([result], generation: model.searchGeneration, credentials: true)

        #expect(model.effectivePlatform == "ps5")          // newest, no sidebar
        model.cyclePlatform(by: 1)                          // ps5 (2) → wrap → ps3 (0)
        #expect(model.effectivePlatform == "ps3")
        model.cyclePlatform(by: -1)                         // ps3 (0) → wrap → ps5 (2)
        #expect(model.effectivePlatform == "ps5")
    }

    @Test func confirmationMessageFromOutcome() {
        let flags = QuickAddFlags(owned: true, played: false, format: .physical)
        #expect(QuickAddModel.confirmationMessage(
            outcome: .created(gameID: 1), title: "Bloodborne", platform: "ps4",
            flags: flags, tier: nil) == "Added Bloodborne · PS4 · owned, physical")
        #expect(QuickAddModel.confirmationMessage(
            outcome: .addedCopy(gameID: 1), title: "Elden Ring", platform: "ps5",
            flags: flags, tier: nil) == "Added a PS5 copy of Elden Ring")
        #expect(QuickAddModel.confirmationMessage(
            outcome: .alreadyPresent(gameID: 1), title: "Ico", platform: "ps2",
            flags: flags, tier: nil).contains("already in your library"))
    }

    // MARK: - Sticky flags + tier

    @Test func stickyFlagsAndRomFormatPersistAcrossInstances() {
        let prefs = InMemoryQuickAddPreferences()
        let m1 = makeQuickAddModel(preferences: prefs)
        #expect(m1.flags.format == .physical)
        m1.cycleFormat()                        // digital
        m1.cycleFormat()                        // rom
        #expect(m1.flags.format == .rom)
        m1.toggleOwned()                        // owned true → false

        let m2 = makeQuickAddModel(preferences: prefs)
        #expect(m2.flags.format == .rom)
        #expect(m2.flags.owned == false)
    }

    @Test func pickingAFormatImpliesOwnedAndIsSticky() {
        let prefs = InMemoryQuickAddPreferences()
        let model = makeQuickAddModel(preferences: prefs)
        if model.flags.owned { model.toggleOwned() }
        #expect(!model.flags.owned)

        model.setFormat(.rom)
        #expect(model.flags.owned)
        #expect(model.flags.format == .rom)

        model.setFormat(.digital)
        #expect(model.flags.format == .digital)

        // A new palette instance starts from the persisted choice.
        let next = makeQuickAddModel(preferences: prefs)
        #expect(next.flags.owned)
        #expect(next.flags.format == .digital)
    }

    @Test func tierImpliesPlayed() {
        let model = makeQuickAddModel()
        #expect(model.flags.played == false)
        model.setTier("A")
        #expect(model.tierLetter == "A")
        #expect(model.flags.played == true)     // a tier implies played
        model.setTier(nil)
        #expect(model.tierLetter == nil)
        #expect(model.flags.played == true)     // clearing the tier does not un-play
    }

    // MARK: - Search (debounce, cancellation, stale-drop)

    @Test func debounceCoalescesAndCancelsPrevious() async throws {
        let catalog = FakeCatalog()
        await catalog.configure(results: [makeSearchResult(id: 1, name: "Zelda")])
        let model = makeQuickAddModel(catalog: catalog, debounce: .milliseconds(30))

        model.query = "zel"
        model.query = "zeld"
        model.query = "zelda"
        try await Task.sleep(for: .milliseconds(150))

        #expect(await catalog.searchCallCount == 1)          // only the final query ran
        #expect(await catalog.lastSearchText == "zelda")
        #expect(model.results.contains { $0.title == "Zelda" })
    }

    @Test func staleResponseNeverOverwritesNewer() {
        let model = makeQuickAddModel(debounce: .seconds(60))    // auto-search won't fire
        model.query = "abc"
        let stale = model.searchGeneration
        model.query = "abcd"
        let current = model.searchGeneration
        #expect(current != stale)

        model.applyRemote([makeSearchResult(id: 1, name: "Stale")], generation: stale, credentials: true)
        #expect(model.results.isEmpty)                          // dropped

        model.applyRemote([makeSearchResult(id: 2, name: "Fresh")], generation: current, credentials: true)
        #expect(model.results.first?.title == "Fresh")
    }

    // MARK: - Commit

    @Test func addAndStayOpenResetsFieldKeepsConfirmation() async {
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 5))
        let model = makeQuickAddModel(library: library)
        model.query = "bloodborne"
        model.applyRemote(
            [makeSearchResult(id: 1, name: "Bloodborne", year: 2015, platforms: ["ps4"])],
            generation: model.searchGeneration, credentials: true)

        model.commit(openInspector: false)
        await poll { model.confirmation != nil }

        #expect(model.query == "")
        #expect(model.tierLetter == nil)
        #expect(model.confirmation?.message.contains("Bloodborne") == true)
        #expect(await library.addedDrafts.count == 1)
        #expect(await library.addedDrafts.first?.igdbID == 1)
    }

    @Test func shiftReturnAddsAndKeepsTheListForSeries() async {
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 5))
        let model = makeQuickAddModel(library: library)
        model.query = "yakuza"
        model.applyRemote(
            [makeSearchResult(id: 1, name: "Yakuza 0", year: 2015, platforms: ["ps4"]),
             makeSearchResult(id: 2, name: "Yakuza Kiwami", year: 2016, platforms: ["ps4"]),
             makeSearchResult(id: 3, name: "Yakuza Kiwami 2", year: 2017, platforms: ["ps4"])],
            generation: model.searchGeneration, credentials: true)
        #expect(model.selectedIndex == 0)

        model.commit(openInspector: false, keepResults: true)
        await poll { model.confirmation != nil && model.selectedIndex == 1 }

        #expect(model.query == "yakuza")                  // field untouched
        #expect(model.results.count == 3)                 // list kept
        #expect(model.selectedIndex == 1)                 // stepped to the next entry
        #expect(model.confirmation?.message.contains("Yakuza 0") == true)
        #expect(await library.addedDrafts.map(\.igdbID) == [1])

        // A second ⇧↩ adds the next game of the series without retyping.
        model.commit(openInspector: false, keepResults: true)
        await poll { model.selectedIndex == 2 }
        #expect(await library.addedDrafts.map(\.igdbID) == [1, 2])
        #expect(model.query == "yakuza")
    }

    @Test func shiftReturnOnTheLastRowStaysOnIt() async {
        let library = FakeLibrary()
        let model = makeQuickAddModel(library: library)
        model.query = "ico"
        model.applyRemote([makeSearchResult(id: 9, name: "Ico", year: 2001, platforms: ["ps2"])],
                          generation: model.searchGeneration, credentials: true)
        model.commit(openInspector: false, keepResults: true)
        await poll { model.confirmation != nil }
        #expect(model.selectedIndex == 0)
        #expect(model.query == "ico")
    }

    @Test func commandReturnOpensInspectorAndCloses() async {
        let captured = Captured()
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 7))
        let model = makeQuickAddModel(library: library)
        model.onOpenInspector = { captured.openedID = $0 }
        model.onRequestClose = { captured.closed = true }
        model.query = "x game"
        model.applyRemote([makeSearchResult(id: 1, name: "X", platforms: ["ps4"])],
                          generation: model.searchGeneration, credentials: true)

        model.commit(openInspector: true)
        await poll { captured.openedID != nil }

        #expect(captured.openedID == 7)
        #expect(captured.closed == true)
    }

    @Test func onLibraryChangedFiresOncePerAdd() async {
        let captured = Captured()
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 1))
        let model = makeQuickAddModel(library: library)
        model.onLibraryChanged = { captured.changeCount += 1 }
        model.query = "x game"
        model.applyRemote([makeSearchResult(id: 1, name: "X", platforms: ["ps4"])],
                          generation: model.searchGeneration, credentials: true)

        model.commit(openInspector: false)
        await poll { model.confirmation != nil }
        #expect(captured.changeCount == 1)
    }

    // MARK: - Bundles

    @Test func bundleAddsAsCompilation() async {
        let catalog = FakeCatalog()
        await catalog.configure(members: [
            makeSearchResult(id: 10, name: "MGS2"),
            makeSearchResult(id: 11, name: "MGS3"),
        ])
        let library = FakeLibrary()
        let model = makeQuickAddModel(catalog: catalog, library: library)
        model.query = "mgs legacy"
        model.applyRemote(
            [makeSearchResult(id: 1, name: "MGS Legacy Collection", platforms: ["ps3"], bundle: true)],
            generation: model.searchGeneration, credentials: true)
        #expect(model.selectedResult?.isBundle == true)

        model.commit(openInspector: false)
        await poll { model.confirmation != nil }

        #expect(await library.addedCompilations.count == 1)
        #expect(await library.addedCompilations.first?.members.count == 2)
        #expect(model.confirmation?.message.contains("compilation") == true)
    }

    @Test func bundleEmptyMembersFallsBackToSingleGame() async {
        let catalog = FakeCatalog()
        await catalog.configure(members: [])                 // IGDB has no member list
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 3))
        let model = makeQuickAddModel(catalog: catalog, library: library)
        model.query = "empty bundle"
        model.applyRemote(
            [makeSearchResult(id: 1, name: "Empty Bundle", platforms: ["ps3"], bundle: true)],
            generation: model.searchGeneration, credentials: true)

        model.commit(openInspector: false)
        await poll { model.confirmation != nil }

        #expect(await library.addedCompilations.isEmpty)
        #expect(await library.addedDrafts.count == 1)        // added as a single game
        #expect(model.confirmation?.message.contains("single game") == true)
    }

    // MARK: - Offline + manual + escape

    @Test func offlineModeShowsLocalAndManualOnly() async throws {
        let catalog = FakeCatalog()
        await catalog.configure(credentials: false)
        let library = FakeLibrary()
        await library.setLocal([makeLibraryMatch(id: 1, title: "Ico", platforms: ["ps2"])])
        let model = makeQuickAddModel(catalog: catalog, library: library, debounce: .milliseconds(20))
        model.prepare(sidebarPlatform: nil, ownedPlatforms: [], tiers: TierInfo.defaultTiers)
        model.query = "ico game"
        try await Task.sleep(for: .milliseconds(150))

        #expect(model.credentialsAvailable == false)
        #expect(model.results.contains { $0.title == "Ico" && $0.source == .local })
        #expect(model.canAddManual == true)
    }

    @Test func manualRowAddsTypedTitleWithPaletteState() async {
        let library = FakeLibrary()
        await library.setOutcome(.created(gameID: 4))
        let model = makeQuickAddModel(library: library)
        model.prepare(sidebarPlatform: "ps4", ownedPlatforms: [], tiers: TierInfo.defaultTiers)
        model.query = "Some Obscure ROM"
        model.cycleFormat()                                   // physical → digital
        model.addManualRow()
        await poll { model.confirmation != nil }

        let draft = await library.addedDrafts.first
        #expect(await library.addedDrafts.count == 1)
        #expect(draft?.title == "Some Obscure ROM")
        #expect(draft?.platformIDs == ["ps4"])
        #expect(draft?.format == .digital)
        #expect(draft?.igdbID == nil)
    }

    @Test func escapeClearsThenCloses() {
        let model = makeQuickAddModel()
        model.query = "abc"
        #expect(model.handleEscape() == true)                 // first esc clears
        #expect(model.query == "")
        #expect(model.handleEscape() == false)                // second esc → caller closes
    }
}
