import Foundation
import Testing
@testable import VGN

@MainActor
struct ManualAddModelTests {

    private var platforms: [PlatformInfo] {
        [
            PlatformInfo(id: "ps4", name: "PlayStation 4", short: "PS4",
                         manufacturer: "Sony", group: "Sony", kind: .console, sort: 20),
            PlatformInfo(id: "pc", name: "PC", short: "PC",
                         manufacturer: "Microsoft", group: "Computer", kind: .computer, sort: 10),
        ]
    }

    @Test func makesDraftFromFields() {
        let model = ManualAddModel(platforms: platforms, tiers: TierInfo.defaultTiers, defaultPlatform: "ps4")
        model.title = "  Halo  "
        model.owned = true
        model.format = .digital
        model.played = true
        model.yearText = "2004"
        model.tierLetter = "A"

        let draft = model.makeDraft()
        #expect(draft?.title == "Halo")               // trimmed
        #expect(draft?.platformIDs == ["ps4"])
        #expect(draft?.owned == true)
        #expect(draft?.format == .digital)
        #expect(draft?.played == true)
        #expect(draft?.year == 2004)
        #expect(draft?.tierID == 2)                    // "A" → tier id 2
        #expect(draft?.source == .manual)
    }

    @Test func defaultPlatformFallsBackToFirst() {
        let model = ManualAddModel(platforms: platforms, defaultPlatform: nil)
        #expect(model.platformID == "ps4")            // first in list
    }

    @Test func emptyTitleYieldsNoDraft() {
        let model = ManualAddModel(platforms: platforms, defaultPlatform: "pc")
        model.title = "   "
        #expect(model.makeDraft() == nil)
        #expect(model.canAdd == false)
    }

    @Test func garbageYearIsDropped() {
        let model = ManualAddModel(platforms: platforms, defaultPlatform: "pc")
        model.title = "Thing"
        model.yearText = "not a year"
        #expect(model.makeDraft()?.year == nil)
        #expect(model.canAdd == true)
    }
}

@MainActor
struct CellBoxDiffingTests {

    private func rows(_ n: Int) -> [GameSummary] {
        (1...n).map { GameSummary(id: Int64($0), title: "Game \($0)", played: true, owned: true) }
    }

    @Test func onlyChangedIDInvalidatesItsBox() async {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: rows(3)))
        vm.start()
        await poll { vm.games.count == 3 }

        let box1 = vm.cellModel(for: 1)
        let box2 = vm.cellModel(for: 2)
        let box2Before = box2.summary

        var changed = vm.games
        changed[0].title = "Renamed"          // id 1 only
        vm.applyGames(changed)

        #expect(vm.cellModel(for: 1) === box1)     // identity preserved
        #expect(vm.cellModel(for: 2) === box2)
        #expect(box1.summary.title == "Renamed")   // changed box updated
        #expect(box2.summary == box2Before)        // untouched box unchanged
    }

    @Test func identicalReapplyLeavesAllBoxesUntouched() async {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: rows(3)))
        vm.start()
        await poll { vm.games.count == 3 }

        let before = (1...3).map { vm.cellModel(for: Int64($0)).summary }
        vm.applyGames(vm.games)                    // identical re-yield
        let after = (1...3).map { vm.cellModel(for: Int64($0)).summary }
        #expect(before == after)
    }
}
