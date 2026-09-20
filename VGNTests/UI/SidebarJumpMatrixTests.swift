import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Wave-19 generalisation of ``SidebarScrollTests``: the owner reported that selecting
/// "Unranked" or "Played" scrolled the sidebar up out of frame — the SAME symptom the
/// wave-17 "Bundles to Expand" bug had. It is the same CLASS of bug: a view mounted in the
/// `NavigationSplitView` **detail** column with an unbounded ideal height (a `Text` carrying
/// `.fixedSize(horizontal: false, vertical: true)`) makes the split view adopt that height for
/// BOTH columns, pushing the sidebar's scroll view up under the title bar. The new instance is
/// ``EmptyStateView`` — shown by ``LibraryGridView`` whenever a grid scope has no rows (a
/// genuinely empty scope, a scope whose first rows have not loaded yet, or a filtered
/// "no matches").
///
/// This suite drives EVERY sidebar selection through the grid content states (loading / empty /
/// populated) in ONE hosted `RootView` window and asserts the sidebar scroll view's geometry is
/// identical (±1 pt) to the `.all`-populated baseline, with the first row reachable at
/// scroll-top. `structuralGuardContainsABadDetailChild` proves the fix is structural: a
/// deliberately-bad `fixedSize` child cannot move the sidebar through `RootView`'s
/// `GeometryReader`-wrapped detail, while the same child WITHOUT the wrap does. No synthetic
/// clicks; selection is driven through the view model.
@MainActor
@Suite(.serialized)
struct SidebarJumpMatrixTests {

    // MARK: Geometry helpers (shared shape with SidebarScrollTests)

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let sv = view as? NSScrollView { out.append(sv) }
        for sub in view.subviews { out.append(contentsOf: scrollViews(sub)) }
        return out
    }

    /// The sidebar's list scroll view: a leading-column scroll view (near the window's left
    /// edge, no wider than a sidebar column), the tallest such if several.
    private func sidebarScrollView(_ window: NSWindow) throws -> NSScrollView {
        let content = try #require(window.contentView)
        let leading = scrollViews(content).filter { sv in
            let f = sv.convert(sv.bounds, to: nil)
            return f.minX < 60 && f.maxX < 380 && f.height > 100
        }
        return try #require(leading.max(by: { $0.frame.height < $1.frame.height }),
                            "no sidebar scroll view found")
    }

    /// The sidebar scroll view's window frame + top inset, read once its height has **settled**
    /// (stable across two run-loop turns AND no taller than the window). Hard-bounded, no
    /// wall-clock assertion.
    private func settledSidebarGeometry(_ window: NSWindow,
                                        timeout: Duration = .seconds(6)) async throws
        -> (frame: NSRect, insetTop: CGFloat) {
        let maxHeight = window.frame.height
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: NSRect?
        while ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            let sv = try sidebarScrollView(window)
            let frame = sv.convert(sv.bounds, to: nil)
            if let last, abs(last.minY - frame.minY) < 0.5, abs(last.height - frame.height) < 0.5,
               frame.height <= maxHeight + 1 {
                return (frame, sv.contentInsets.top)
            }
            last = frame
            try await Task.sleep(for: .milliseconds(50))
        }
        let sv = try sidebarScrollView(window)
        return (sv.convert(sv.bounds, to: nil), sv.contentInsets.top)
    }

    /// A single, immediate reading of the sidebar frame (no settle wait). Used where the frame is
    /// EXPECTED to be oversized — waiting for a settle that never comes only burns the timeout.
    private func rawSidebarFrame(_ window: NSWindow) throws -> NSRect {
        window.contentView?.layoutSubtreeIfNeeded()
        let sv = try sidebarScrollView(window)
        return sv.convert(sv.bounds, to: nil)
    }

    @discardableResult
    private func firstRowReachable(_ window: NSWindow) async throws -> Bool {
        let sv = try sidebarScrollView(window)
        sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top))
        sv.reflectScrolledClipView(sv.contentView)
        try await Task.sleep(for: .milliseconds(50))
        return sv.documentVisibleRect.minY <= 1
    }

    private func expectMatches(_ label: String, _ got: (frame: NSRect, insetTop: CGFloat),
                               baseline base: (frame: NSRect, insetTop: CGFloat),
                               file: StaticString = #filePath, line: UInt = #line) {
        #expect(abs(base.frame.minY - got.frame.minY) < 1,
                "\(label): sidebar top shifted (baseline \(base.frame) vs \(got.frame))")
        #expect(abs(base.frame.maxY - got.frame.maxY) < 1, "\(label): sidebar bottom shifted")
        #expect(abs(base.frame.height - got.frame.height) < 1, "\(label): sidebar height changed")
        #expect(abs(base.insetTop - got.insetTop) < 1, "\(label): sidebar top inset changed")
    }

    // MARK: Focused reproduction — a single empty grid scope must not move the sidebar

    @Test(.timeLimit(.minutes(2)))
    func emptyGridScopeDoesNotMoveTheSidebar() async throws {
        let source = SidebarJumpDataSource()
        let vm = LibraryViewModel(dataSource: source, selection: .all)
        let probe = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 500),
                                     size: NSSize(width: 900, height: 520))
        defer { probe.close() }
        try await probe.settle()

        await poll { vm.games.count > 0 }
        let base = try await settledSidebarGeometry(probe.window)

        source.set(.empty, for: SidebarSelection.played.id)
        vm.select(.played)
        await poll { vm.gamesLoaded && vm.games.isEmpty }
        let empty = try await settledSidebarGeometry(probe.window)

        print("[jump] baseline=\(base.frame) | empty(played)=\(empty.frame)")
        expectMatches("empty played", empty, baseline: base)
        try await firstRowReachable(probe.window)
    }

    // MARK: The full matrix — every selection × every grid content state

    @Test(.timeLimit(.minutes(4)))
    func everySelectionAndStateLeavesTheSidebarPut() async throws {
        let source = SidebarJumpDataSource()
        let vm = LibraryViewModel(dataSource: source, selection: .all)
        let probe = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 500),
                                     size: NSSize(width: 900, height: 540))
        defer { probe.close() }
        try await probe.settle()

        // Baseline: All, populated → the grid.
        await poll { vm.games.count > 0 && vm.gamesLoaded }
        let base = try await settledSidebarGeometry(probe.window)

        // Every grid scope the sidebar can produce.
        var gridScopes: [SidebarSelection] = [
            .all, .owned, .played, .backlog, .unranked, .unlinked, .bundlesToExpand, .unmeasured,
            .platform("ps5"), .platform("snes"),
        ]
        gridScopes += SidebarSelection.lengthShelves

        for scope in gridScopes {
            // POPULATED
            source.reset()
            select(vm, scope)
            await poll { vm.gamesLoaded && !vm.games.isEmpty }
            expectMatches("populated \(scope.id)", try await settledSidebarGeometry(probe.window), baseline: base)

            // EMPTY (the EmptyStateView branch — the leak-prone one)
            source.set(.empty, for: scope.id)
            reselect(vm, scope)          // force a fresh observation for the same scope
            await poll { vm.gamesLoaded && vm.games.isEmpty }
            expectMatches("empty \(scope.id)", try await settledSidebarGeometry(probe.window), baseline: base)
        }

        // LOADING (the owner's exact case: a big scope whose rows have not arrived). Reach it
        // deterministically: land on an empty scope so `games` is empty, then select a scope whose
        // observation never emits — the grid must show the quiet placeholder, not the empty state.
        for scope in [SidebarSelection.played, .unranked] {
            source.set(.empty, for: SidebarSelection.owned.id)
            select(vm, .owned)
            await poll { vm.gamesLoaded && vm.games.isEmpty }

            source.set(.loading, for: scope.id)
            select(vm, scope)
            await poll { !vm.gamesLoaded && vm.games.isEmpty }   // loading: not yet delivered
            expectMatches("loading \(scope.id)", try await settledSidebarGeometry(probe.window), baseline: base)
        }

        // Non-grid destinations render their own views inside the same detail container.
        source.reset()
        for scope: SidebarSelection in [.playNext, .tierBoard, .theTop, .duel, .vault(.batocera), .vault(.psn)] {
            select(vm, scope)
            await poll { vm.gamesLoaded }
            expectMatches("non-grid \(scope.id)", try await settledSidebarGeometry(probe.window), baseline: base)
        }

        // Back to a populated grid — the first sidebar rows are reachable at the top.
        source.reset()
        select(vm, .all)
        await poll { vm.gamesLoaded && !vm.games.isEmpty }
        #expect(try await firstRowReachable(probe.window),
                "the first sidebar rows must be reachable by scrolling to the top")
    }

    /// Select, tolerating the "same selection" no-op guard by first bouncing through `.all`.
    private func select(_ vm: LibraryViewModel, _ scope: SidebarSelection) {
        if vm.selection == scope { reselect(vm, scope) } else { vm.select(scope) }
    }

    /// Force a fresh grid observation for a scope that is already selected (the view model's
    /// `select` is a no-op for the current selection): bounce through `.all` and back.
    private func reselect(_ vm: LibraryViewModel, _ scope: SidebarSelection) {
        if scope == .all { vm.select(.owned) } else { vm.select(.all) }
        vm.select(scope)
    }

    // MARK: Structural guard — a deliberately-bad detail child cannot move the sidebar

    /// A view with a `.fixedSize(horizontal: false, vertical: true)` multi-line `Text` — the exact
    /// unbounded-ideal-height shape that leaks. Mirrors what any future detail view might do wrong.
    private struct BadDetailChild: View {
        var body: some View {
            VStack {
                Text("A deliberately bad, very long, multi-line message that wraps across many "
                     + "lines to force an unbounded ideal height when fixedSize(vertical: true) is "
                     + "applied to it directly inside the detail column of a navigation split view.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Mirrors ``RootView``'s detail container: a fixed-height header bar in the outer `VStack`,
    /// then the destination area. `wrapped` applies the same `GeometryReader` guard `RootView`
    /// uses; unwrapped is the naive structure that leaks.
    private struct DetailReplica<Child: View>: View {
        let wrapped: Bool
        @ViewBuilder let child: () -> Child
        var body: some View {
            VStack(spacing: 0) {
                Color.gray.opacity(0.2).frame(height: 28)   // a slim header bar
                if wrapped {
                    GeometryReader { geo in
                        ZStack { child() }.frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    ZStack { child() }
                }
            }
        }
    }

    private func hostReplica(wrapped: Bool) -> ClickProbeWindow {
        let split = NavigationSplitView {
            List { ForEach(0..<40, id: \.self) { Text("Row \($0)") } }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            DetailReplica(wrapped: wrapped) { BadDetailChild() }
        }
        return ClickProbeWindow(split.frame(minWidth: 900, minHeight: 500),
                                size: NSSize(width: 900, height: 520))
    }

    @Test(.timeLimit(.minutes(3)))
    func structuralGuardContainsABadDetailChild() async throws {
        // Without the guard, the bad child grows the sidebar scroll view well past the window
        // (this asserts the test has teeth — the bad child really does leak).
        let naive = hostReplica(wrapped: false)
        defer { naive.close() }
        try await naive.settle()
        let naiveFrame = try rawSidebarFrame(naive.window)   // expected oversized — measure directly
        #expect(naiveFrame.height > naive.window.frame.height + 50,
                "a bad fixedSize child SHOULD leak without the GeometryReader guard (got \(naiveFrame))")

        // With the same guard RootView uses, the identical child cannot move the sidebar — its
        // frame fits the window and its top is flush.
        let guarded = hostReplica(wrapped: true)
        defer { guarded.close() }
        try await guarded.settle()
        let guardedGeom = try await settledSidebarGeometry(guarded.window)
        print("[struct] naive=\(naiveFrame) guarded=\(guardedGeom.frame) window=\(guarded.window.frame.height)")
        #expect(guardedGeom.frame.height <= guarded.window.frame.height + 1,
                "the GeometryReader guard must keep the sidebar within the window (got \(guardedGeom.frame))")
        #expect(abs(guardedGeom.frame.minY) < 1,
                "the guarded sidebar must stay flush at the top (got \(guardedGeom.frame))")
    }
}

/// A controllable ``LibraryDataSource`` for the sidebar-jump matrix: counts come from a fixed,
/// non-empty base library (so `isEmptyLibrary` is false and the sidebar is fully populated),
/// while each scope's grid rows can be made **populated**, **empty**, or **loading** (a stream
/// that never emits) on demand. MainActor-confined in the tests; the class is only read/mutated
/// from the test's actor, so `@unchecked Sendable` is safe here.
final class SidebarJumpDataSource: LibraryDataSource, @unchecked Sendable {
    enum Mode { case populated, empty, loading }

    private let base: [GameSummary]
    private var modes: [String: Mode] = [:]

    init() {
        let platforms = ["ps5", "ps4", "switch", "snes", "pc"]
        let tiers = TierInfo.defaultTiers
        var games: [GameSummary] = []
        for i in 0..<60 {
            let played = i % 3 != 0
            let hasTier = played && i % 2 == 0
            let tier = tiers[i % tiers.count]
            games.append(GameSummary(
                id: Int64(1000 + i),
                title: "Jump Game \(i + 1)",
                year: 1990 + (i % 30),
                tierID: hasTier ? tier.id : nil,
                tierLetter: hasTier ? tier.letter : nil,
                tierColorHex: hasTier ? tier.colorHex : nil,
                rankKey: hasTier ? RankKey(i * 100) : nil,
                played: played,
                owned: i % 4 != 0,
                platformIDs: [platforms[i % platforms.count]],
                status: played ? PlayStatus.allCases[i % PlayStatus.allCases.count] : nil))
        }
        base = games
    }

    func set(_ mode: Mode, for scopeID: String) { modes[scopeID] = mode }
    func reset() { modes.removeAll() }

    func sidebarCounts(pace: PlayPace, style: PlayStyle) -> AsyncStream<SidebarCounts> {
        onceStream(SidebarCounts.derive(from: base))
    }
    func platformsInUse() -> AsyncStream<[PlatformInfo]> {
        let inUse = Set(base.flatMap(\.platformIDs))
        return onceStream(PlatformLabels.all.filter { inUse.contains($0.id) })
    }
    func tiers() -> AsyncStream<[TierInfo]> { onceStream(TierInfo.defaultTiers) }
    func genresInUse() -> AsyncStream<[String]> { onceStream([]) }
    func decadesInUse() -> AsyncStream<[Int]> {
        onceStream(Set(base.compactMap { $0.year.map { ($0 / 10) * 10 } }).sorted())
    }

    func games(filter: LibraryFilter) -> AsyncStream<[GameSummary]> {
        switch modes[filter.scope.id] ?? .populated {
        case .populated:
            let rows = LibraryFilterEvaluator.apply(filter, to: base)
            // Never let a "populated" scope be accidentally empty (some scopes are no-constraint
            // in the in-memory evaluator) — fall back to the whole base so the grid renders.
            return onceStream(rows.isEmpty
                ? LibraryFilterEvaluator.sorted(base, by: filter.sort, ascending: filter.ascending)
                : rows)
        case .empty:
            return onceStream([])
        case .loading:
            return AsyncStream { _ in }   // open, never emits — models a not-yet-delivered scope
        }
    }

    func gameDetail(id: Int64) async -> GameDetail? {
        base.first { $0.id == id }.map(GameDetail.init(previewFrom:))
    }
    func gameDetailStream(id: Int64) -> AsyncStream<GameDetail?> {
        onceStream(base.first { $0.id == id }.map(GameDetail.init(previewFrom:)))
    }
}
