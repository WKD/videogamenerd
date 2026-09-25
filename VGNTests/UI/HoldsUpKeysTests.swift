import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VGN

/// Wave 22 — "Holds up today?" on ONE keystroke (⇧ at most), routed by the pure
/// ``GridKeyRouter`` like the ⇧-tier keys (never a menu key equivalent). The table:
///
/// | scope                          | 1 / 2 / 3        | 0              | ⇧1 / ⇧2 / ⇧3 | ⇧0    |
/// |--------------------------------|------------------|----------------|--------------|-------|
/// | any grid scope                 | type-select      | clear the TIER | rate         | clear |
/// | "Needs a 'Holds Up' Rating"    | rate             | clear the MARK | rate         | clear |
@MainActor
struct HoldsUpKeyRouterTests {

    private func r(_ c: String, _ m: EventModifiers = [], list: Bool = false, digit: Int? = nil) -> GridKeyAction? {
        GridKeyRouter.route(characters: c, modifiers: m, inHoldsUpList: list, digitKey: digit)
    }

    @Test func normalScopesUseShiftDigits() {
        // US layout: ⇧1 arrives as "!", ⇧2 "@", ⇧3 "#", ⇧0 ")".
        #expect(r("!", .shift) == .holdsUp(.holdsUp))
        #expect(r("@", .shift) == .holdsUp(.ofItsTime))
        #expect(r("#", .shift) == .holdsUp(.tooArchaic))
        #expect(r(")", .shift) == .holdsUp(nil))
        // Same keys with the physical key code known (any layout, e.g. AZERTY "1" with ⇧).
        #expect(r("1", .shift, digit: 1) == .holdsUp(.holdsUp))
        #expect(r("&", .shift, digit: 1) == .holdsUp(.holdsUp))
        #expect(r("à", .shift, digit: 0) == .holdsUp(nil))
        // Plain digits keep their old meaning outside the list.
        #expect(r("1") == .typeSelect("1"))
        #expect(r("3") == .typeSelect("3"))
        #expect(r("0") == .clearTier)
        // ⇧ + other digits act on nothing.
        #expect(r("%", .shift) == nil)
        #expect(r("%", .shift, digit: 5) == nil)
        // The existing ⇧ letters are untouched.
        #expect(r("s", .shift) == .tier("S"))
        #expect(r("m", .shift) == .markPlayedAsLast)
    }

    @Test func holdsUpListUsesPlainDigitsAndZeroClearsTheMark() {
        #expect(r("1", list: true) == .holdsUp(.holdsUp))
        #expect(r("2", list: true) == .holdsUp(.ofItsTime))
        #expect(r("3", list: true) == .holdsUp(.tooArchaic))
        #expect(r("0", list: true) == .holdsUp(nil))           // NOT .clearTier in this list
        #expect(r("!", .shift, list: true) == .holdsUp(.holdsUp))
        // Other digits and letters still type-select; ⇧ letters still act.
        #expect(r("4", list: true) == .typeSelect("4"))
        #expect(r("z", list: true) == .typeSelect("z"))
        #expect(r("a", .shift, list: true) == .tier("A"))
        // AZERTY: plain top-row "é" is key 2 → rates in the list.
        #expect(r("é", list: true, digit: 2) == .holdsUp(.ofItsTime))
        // …but outside the list, a plain "é" is still a letter to type-select.
        #expect(r("é", digit: 2) == .typeSelect("é"))
    }

    @Test func keyCodesAndHints() {
        #expect(GridKeyRouter.topRowDigit(keyCode: 18) == 1)
        #expect(GridKeyRouter.topRowDigit(keyCode: 19) == 2)
        #expect(GridKeyRouter.topRowDigit(keyCode: 20) == 3)
        #expect(GridKeyRouter.topRowDigit(keyCode: 29) == 0)
        #expect(GridKeyRouter.topRowDigit(keyCode: 0) == nil)       // "a"
        #expect(GridKeyRouter.holdsUpHint(for: .holdsUp) == "⇧1")
        #expect(GridKeyRouter.holdsUpHint(for: nil) == "⇧0")
        #expect(GridKeyRouter.holdsUpHint(for: .tooArchaic, inHoldsUpList: true) == "3")
        #expect(HoldsUpMenuItems.title("Holds Up", .holdsUp, hints: true) == "Holds Up   ⇧1")
        #expect(HoldsUpMenuItems.title("Clear (Unrated)", nil, hints: true) == "Clear (Unrated)   ⇧0")
        #expect(HoldsUpInspectorRow.keyHint(for: .ofItsTime) == "⇧2 in the grid")
    }
}

/// The routed action through the wired view model: rates the selection, and does nothing while
/// the search field owns focus (typing "!" / "1" there never rates a game).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HoldsUpKeyActionTests {

    @Test func searchFieldFocusSuppressesTheKeys() async throws {
        let store = try await UIWiring.makeStore()
        let a = try await store.addGame(GameDraft(title: "A", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let b = try await store.addGame(GameDraft(title: "B", platformIDs: ["ps4"], owned: true, played: true)).gameID
        let vm = LibraryViewModel(dataSource: GRDBLibraryDataSource(store: store))
        let actions = LibraryActions(store: store, vm: vm)
        actions.install()
        vm.undoManager = UndoManager()
        vm.start()
        for _ in 0..<2000 where vm.games.count < 2 { await Task.yield() }
        #expect(vm.games.count == 2)

        vm.selectOnly(a)
        vm.searchFieldFocused = true
        #expect(vm.applyGridAction(.holdsUp(.tooArchaic)) == nil)
        vm.searchFieldFocused = false
        vm.selectOnly(b)
        vm.applyGridAction(.holdsUp(.holdsUp))
        var markB: HoldsUp?
        for _ in 0..<400 {
            markB = try await store.gameDetail(id: b)?.holdsUp
            if markB != nil { break }
            await Task.yield()
        }
        #expect(markB == .holdsUp)
        #expect(try await store.gameDetail(id: a)?.holdsUp == nil)   // the focused key did nothing
    }
}

/// A hosted click on the "Needs a 'Holds Up' Rating" header buttons (real mouse events,
/// off-screen window). The header holds only plain buttons (no `Menu`); sweeps stay in its band.
@MainActor
@Suite(.serialized)
struct HoldsUpRatingHeaderClickTests {

    final class Box { var picked: [HoldsUp?] = [] }

    private func host(canRate: Bool, showsClear: Bool, _ box: Box) async throws -> ClickProbeWindow {
        let header = HoldsUpRatingHeader(canRate: canRate, showsClear: showsClear) { box.picked.append($0) }
        let probe = ClickProbeWindow(VStack(spacing: 0) { header; Spacer() }.frame(width: 760, height: 140),
                                     size: NSSize(width: 760, height: 140))
        try await probe.settle()
        return probe
    }

    private func band(_ probe: ClickProbeWindow) -> ClickProbeWindow.SweepRegion {
        .init(xMin: 200, xMax: 750, yTop: probe.contentTop - 6, yBottom: probe.contentTop - 28)
    }

    @Test(.timeLimit(.minutes(2)))
    func eachButtonRatesItsValue() async throws {
        let box = Box()
        let probe = try await host(canRate: true, showsClear: false, box)
        defer { probe.close() }
        // Left-to-right reaches Holds Up first, then Of Its Time; right-to-left reaches Too Archaic.
        #expect(await probe.sweepUntil(region: band(probe), stepX: 10, stepY: 6) { box.picked.contains(.holdsUp) })
        #expect(await probe.sweepUntil(region: band(probe), stepX: 10, stepY: 6) { box.picked.contains(.ofItsTime) })
        #expect(await probe.sweepUntil(region: band(probe), stepX: 10, stepY: 6, rightToLeft: true) {
            box.picked.contains(.tooArchaic)
        })
        #expect(!box.picked.contains(where: { $0 == nil }))          // no Clear without a mark
    }

    @Test(.timeLimit(.minutes(2)))
    func clearAppearsWithAMarkAndClears() async throws {
        let box = Box()
        let probe = try await host(canRate: true, showsClear: true, box)
        defer { probe.close() }
        // Clear is the right-most control (a small borderless one — a sweep row may graze
        // Too Archaic first, which is fine: we wait for the clear itself).
        let hit = await probe.sweepUntil(region: band(probe), stepX: 6, stepY: 3, rightToLeft: true) {
            box.picked.contains(where: { $0 == nil })
        }
        #expect(hit, "the Clear button never reacted")
    }

    @Test(.timeLimit(.minutes(2)))
    func disabledWithoutASelection() async throws {
        let box = Box()
        let probe = try await host(canRate: false, showsClear: false, box)
        defer { probe.close() }
        let hit = await probe.sweepUntil(region: band(probe), stepX: 24, stepY: 10) { !box.picked.isEmpty }
        #expect(!hit)
        #expect(box.picked.isEmpty)
    }
}
