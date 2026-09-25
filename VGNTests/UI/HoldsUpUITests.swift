import AppKit
import Foundation
import SwiftUI
import Testing
@testable import VGN

/// The UI side of "Holds up today?" (PLAN §7b/§8) that needs no database: mixed-state menu
/// over a mixed selection (incl. the unplayed footer), the sidebar smart list's id / count /
/// title / evaluator, chips, Triage keys, the inspector row at 300 pt.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HoldsUpUITests {

    private func g(_ id: Int64, played: Bool = true, _ mark: HoldsUp? = nil) -> GameSummary {
        GameSummary(id: id, title: "G\(id)", played: played, owned: true, platformIDs: ["ps4"], holdsUp: mark)
    }

    // MARK: - Mixed-state menu

    @Test func mixedStateIsComputedOverPlayedGamesOnly() {
        // Two played games (Holds Up + Of Its Time), one played unrated, two unplayed.
        let selection = [g(1, .holdsUp), g(2, .ofItsTime), g(3), g(4, played: false), g(5, played: false)]
        #expect(selection.holdsUpState(.holdsUp) == .some)
        #expect(selection.holdsUpState(.ofItsTime) == .some)
        #expect(selection.holdsUpState(.tooArchaic) == .none)
        #expect(selection.holdsUpState(nil) == .some)            // "Clear (Unrated)" – mixed
        #expect(selection.unplayedCount == 2)
        #expect(HoldsUpMenuItems.unplayedFooter(2) == "2 unplayed games not changed")
        #expect(HoldsUpMenuItems.unplayedFooter(1) == "1 unplayed game not changed")

        // The unplayed games never spoil an "all": every PLAYED game Too Archaic ⇒ ✓.
        let allArchaic = [g(1, .tooArchaic), g(2, .tooArchaic), g(3, played: false)]
        #expect(allArchaic.holdsUpState(.tooArchaic) == .all)
        #expect(allArchaic.holdsUpState(nil) == .none)
        // A selection of only unplayed games shows no state at all.
        #expect([g(1, played: false)].holdsUpState(nil) == .none)
    }

    // MARK: - Sidebar smart list

    @Test func sidebarRowIdentityCountAndLabel() {
        #expect(SidebarSelection.needsHoldsUpRating.id == "needsHoldsUpRating")
        var counts = SidebarCounts(all: 10)
        #expect(counts.count(for: .needsHoldsUpRating) == 0)       // hidden by the view at 0
        counts.needsHoldsUpRating = 4
        #expect(counts.count(for: .needsHoldsUpRating) == 4)
        #expect(SidebarView.title(for: .needsHoldsUpRating) == "Needs a \u{201C}Holds Up\u{201D} Rating")
        #expect(!SidebarView.icon(for: .needsHoldsUpRating).isEmpty)
        // The restore path is keyed by the stable id (per-selection sort).
        let suite = "vgn-hu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        UserDefaultsSortPreferences(defaults: defaults)
            .setSortSetting(SortSetting(sort: .year, ascending: true), for: SidebarSelection.needsHoldsUpRating.id)
        #expect(UserDefaultsSortPreferences(defaults: defaults).sortSetting(for: "needsHoldsUpRating")
                == SortSetting(sort: .year, ascending: true))
    }

    @Test func previewCountEqualsTheScopedList() {
        let games = [g(1, .holdsUp), g(2), g(3), g(4, played: false)]
        let counts = SidebarCounts.derive(from: games)
        let list = LibraryFilterEvaluator.apply(LibraryFilter(scope: .needsHoldsUpRating), to: games)
        #expect(counts.needsHoldsUpRating == 2)
        #expect(Set(list.map(\.id)) == [2, 3])
        #expect(list.count == counts.needsHoldsUpRating)
    }

    @Test func selectingTheListScopesTheGridAndSortsBestFirst() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []))
        vm.select(.needsHoldsUpRating)
        #expect(vm.filter.scope == .needsHoldsUpRating)
        #expect(vm.isNeedsHoldsUpRatingSelection)
        #expect(vm.showsGridToolbar)
        #expect(LibraryViewModel.defaultSort(for: .needsHoldsUpRating) == .tierRank)
    }

    // MARK: - Filter chips

    @Test func chipsListMarksThenUnratedAndRemoveOneByOne() {
        var f = LibraryFilter(holdsUp: [.tooArchaic, .holdsUp], includeHoldsUpUnrated: true)
        #expect(f.hasActiveFacets)
        let chips = LibraryFilterChips.chips(for: f).filter { $0.kind == .holdsUp }
        #expect(chips.map(\.text) == ["Holds Up: Holds Up", "or Too Archaic", "or Unrated"])
        f = LibraryFilterChips.removing(chips[2], from: f)
        #expect(!f.includeHoldsUpUnrated)
        f = LibraryFilterChips.removing(chips[0], from: f)
        #expect(f.holdsUp == [.tooArchaic])
        #expect(LibraryFilterChips.cleared(f).holdsUp.isEmpty)
    }

    // MARK: - Triage keys

    @Test func triageKeysRateWithoutAdvancingAndToggleOff() async {
        let b = ScriptedRankingBackend()
        b.unranked = [g(10), g(11)]
        let m = TriageModel(backend: b)
        await m.start()

        #expect(await m.handle(character: "3"))                   // Too Archaic
        #expect(b.holdsUpCalls.count == 1)
        #expect(b.holdsUpCalls[0].value == .tooArchaic && b.holdsUpCalls[0].ids == [10])
        #expect(m.current?.id == 10)                               // did NOT advance
        #expect(m.current?.holdsUp == .tooArchaic)                 // the card shows it at once
        #expect(m.tieredCount == 0)

        #expect(await m.handle(character: "1"))                   // change to Holds Up
        #expect(m.current?.holdsUp == .holdsUp)
        #expect(await m.handle(character: "1"))                   // again ⇒ back to Unrated
        #expect(b.holdsUpCalls.last?.value == nil)
        #expect(m.current?.holdsUp == nil)

        #expect(await m.handle(character: "2"))
        #expect(b.holdsUpCalls.last?.value == .ofItsTime)
        // Tiering still advances, as before.
        await m.tierCurrent(1)
        #expect(m.current?.id == 11)
        #expect(TriageView.legendText.contains("1 Holds Up"))
        #expect(TriageView.legendText.contains("3 Too Archaic"))
    }

    // MARK: - Inspector row

    private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The control fits the 300 pt minimum inspector column (268 pt inner) with a bounded height
    /// in every state — no letter-by-letter squeeze, never an unbounded height.
    @Test func inspectorRowFitsTheMinimumColumn() {
        let first = Calendar(identifier: .gregorian).date(from: DateComponents(year: 1991, month: 6, day: 1))!
        for mark in [nil, HoldsUp.holdsUp, .ofItsTime, .tooArchaic] {
            let row = HoldsUpInspectorRow(current: mark, firstPlayedAt: first) { _ in }
            let narrow = fittingHeight(row, width: 268)
            #expect(narrow > 0 && narrow.isFinite)
            #expect(narrow < 170, "Holds Up row too tall at 300 pt: \(narrow)")
        }
        #expect(FirstPlayedCaption.text(first, calendar: Calendar(identifier: .gregorian)) == "First played in 1991")
        #expect(FirstPlayedCaption.text(nil) == nil)
        #expect(HoldsUpInspectorRow.keyHint(for: .ofItsTime) == "⇧2 in the grid")
        #expect(HoldsUpInspectorRow.keyHint(for: nil) == "⇧0 in the grid")
    }
}

/// A hosted click on the inspector's Holds Up segments (real mouse events, off-screen window).
/// The row holds only plain buttons (no `Menu`), and the sweep is bounded to the row's band.
@MainActor
@Suite(.serialized)
struct HoldsUpInspectorClickTests {

    @Test(.timeLimit(.minutes(2)))
    func clickingASegmentPicksItsValue() async throws {
        final class Box { var picked: [HoldsUp?] = [] }
        let box = Box()
        let row = HoldsUpInspectorRow(current: nil) { box.picked.append($0) }
            .padding(16)
            .frame(width: 300, alignment: .topLeading)
        let probe = ClickProbeWindow(VStack(spacing: 0) { row; Spacer() }.frame(width: 300, height: 220),
                                     size: NSSize(width: 300, height: 220))
        defer { probe.close() }
        try await probe.settle()

        // Sweep the band under the title bar where the segments sit, right-to-left so the
        // right-most segment (Too Archaic, or the Clear glyph above it — disabled when unrated)
        // is reached first. Stop at the first pick.
        let top = probe.contentTop
        let hit = await probe.sweepUntil(
            region: .init(xMin: 20, xMax: 280, yTop: top - 36, yBottom: top - 90),
            stepX: 12, stepY: 6, rightToLeft: true) { !box.picked.isEmpty }
        #expect(hit, "no Holds Up segment reacted to a click")
        #expect(box.picked.first.map { $0 != nil } == true)       // a value, never a stray clear
    }
}
