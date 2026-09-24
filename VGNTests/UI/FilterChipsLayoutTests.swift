import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The filter bar's "N of M games" count (owner 2026-09-25): pinned to the bar's trailing
/// edge (inset = the grid's content inset), vertically centred on the FIRST chip row — with
/// one row and with several wrapped rows — and present for a search-only filter too.
@MainActor
@Suite(.serialized)
struct FilterChipsLayoutTests {

    @MainActor final class Frames {
        var byPart: [FilterChipsBarPart: CGRect] = [:]
        var complete: Bool { byPart[.bar] != nil && byPart[.firstChip] != nil && byPart[.count] != nil }
    }

    private func loadedVM(_ configure: (inout LibraryFilter) -> Void,
                          selection: SidebarSelection? = nil) async -> LibraryViewModel {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        vm.start()
        if let selection { vm.select(selection) }
        var f = vm.filter
        configure(&f)
        vm.setFilter(f)
        await poll { vm.gamesLoaded }
        return vm
    }

    /// Host the bar alone at `width`, returning its reported frames once all three arrived.
    private func layout(_ vm: LibraryViewModel, width: CGFloat) async throws -> (ClickProbeWindow, Frames) {
        let frames = Frames()
        let view = VStack(spacing: 0) {
            FilterChipsBar(vm: vm, layoutProbe: { part, rect in frames.byPart[part] = rect })
            Color.clear
        }
        .frame(width: width, height: 400)
        let window = ClickProbeWindow(view, size: NSSize(width: width, height: 400))
        try await window.settle()
        _ = await window.poll { frames.complete }
        try #require(frames.complete, "the bar never reported its bar/chip/count frames")
        return (window, frames)
    }

    private func expectAligned(_ f: Frames, rows expectedRows: ClosedRange<Int>) {
        let bar = f.byPart[.bar]!, chip = f.byPart[.firstChip]!, count = f.byPart[.count]!
        // Trailing: the count ends at the bar's trailing inset (= the grid's content inset).
        #expect(abs(count.maxX - (bar.maxX - FilterChipsBar.horizontalInset)) <= 1,
                "count maxX \(count.maxX) vs bar \(bar.maxX) − \(FilterChipsBar.horizontalInset)")
        #expect(FilterChipsBar.horizontalInset == LibraryGridView.contentInset)
        // Leading: chips start at the same inset.
        #expect(abs(chip.minX - (bar.minX + FilterChipsBar.horizontalInset)) <= 1)
        // Vertical: centred on the FIRST chip row, not the middle of a multi-row bar.
        #expect(abs(count.midY - chip.midY) <= 1.5, "count midY \(count.midY) vs first chip \(chip.midY)")
        // Never beside/under the chips' last row: single line, fully visible.
        #expect(count.height < chip.height + 1)
        // Row count sanity (so the multi-row case really is multi-row).
        let rows = Int(((bar.height - 12) + 6) / (chip.height + 6) + 0.5)
        #expect(expectedRows.contains(rows), "expected \(expectedRows) chip rows, laid out \(rows)")
    }

    @Test(.timeLimit(.minutes(2)))
    func countPinnedTrailingOnASingleRow() async throws {
        let vm = await loadedVM { $0.genres = ["RPG"] }
        let (window, frames) = try await layout(vm, width: 900)
        defer { window.close() }
        expectAligned(frames, rows: 1...1)
    }

    @Test(.timeLimit(.minutes(2)))
    func countCentredOnTheFirstOfThreeRows() async throws {
        let vm = await loadedVM {
            $0.searchText = "a"
            $0.genres = ["RPG", "Adventure"]
            $0.tierIDs = [1, 2]
            $0.formats = [.rom, .physical]
            $0.platforms = ["ps4", "snes"]
        }
        let (window, frames) = try await layout(vm, width: 400)
        defer { window.close() }
        expectAligned(frames, rows: 3...4)
    }

    /// A search alone is a chip, so the bar (and its count) shows for a search-only filter.
    @Test(.timeLimit(.minutes(2)))
    func searchOnlyShowsTheBarWithTheCount() async throws {
        let vm = await loadedVM { $0.searchText = "a" }
        #expect(!vm.filterChips.isEmpty)
        let (window, frames) = try await layout(vm, width: 900)
        defer { window.close() }
        expectAligned(frames, rows: 1...1)
    }

    /// Nothing filtered → no bar at all (the grid's top edge is unchanged).
    @Test(.timeLimit(.minutes(2)))
    func unfilteredHidesTheBar() async throws {
        let vm = await loadedVM { _ in }
        #expect(vm.filterChips.isEmpty)
        let frames = Frames()
        let window = ClickProbeWindow(
            FilterChipsBar(vm: vm, layoutProbe: { part, rect in frames.byPart[part] = rect })
                .frame(width: 600, height: 200),
            size: NSSize(width: 600, height: 200))
        defer { window.close() }
        try await window.settle()
        #expect(frames.byPart.isEmpty)
    }

    /// Narrow bar: the chips wrap first; when the full line still cannot fit beside the
    /// widest chip the count drops its "of M" part instead of truncating mid-number.
    @Test(.timeLimit(.minutes(2)))
    func narrowBarFallsBackToTheCompactCount() async throws {
        let vm = await loadedVM { $0.genres = ["RPG"] }
        let (window, frames) = try await layout(vm, width: 900)
        let wide = frames.byPart[.count]!.width
        window.close()
        // Room for the chip but not for "N of M games" beside it.
        let chipWidth = frames.byPart[.firstChip]!.width
        let narrow = chipWidth + 2 * FilterChipsBar.horizontalInset + 12 + wide - 12
        let (window2, frames2) = try await layout(vm, width: narrow)
        defer { window2.close() }
        let count = frames2.byPart[.count]!
        #expect(count.width < wide, "the count should switch to its compact form")
        #expect(count.maxX <= frames2.byPart[.bar]!.maxX - FilterChipsBar.horizontalInset + 1)
    }

    /// With the count present, a scoped search's "Search all" is still clickable (right-to-
    /// left sweep of the bar band — it holds only chips/buttons/text, no menus).
    @Test(.timeLimit(.minutes(5)))
    func searchAllClickableBesideTheCount() async throws {
        let vm = await loadedVM({ $0.searchText = "a" }, selection: .platform("snes"))
        #expect(vm.selection != .all)
        let bar = VStack(spacing: 0) { FilterChipsBar(vm: vm); Color.clear }.toolbar { Button("X") {} }
        let window = ClickProbeWindow(bar.frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        _ = try await window.sweep(band: 40, stepX: 8, stepY: 6, rightToLeft: true) {
            vm.selection == .all ? 1 : 0
        } until: { vm.selection == .all }
        #expect(vm.selection == .all)
    }
}
