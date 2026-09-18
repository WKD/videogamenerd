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
