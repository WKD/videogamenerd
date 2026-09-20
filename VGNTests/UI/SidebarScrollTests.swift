import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Regression for the owner's wave-17 sidebar bug: entering "Bundles to Expand" drew the
/// sidebar rows under the title bar and made the top unreachable. The cause was the Bundles
/// header being wrapped in an inner `VStack { header; grid }` inside the detail's ZStack —
/// unlike `FilterChipsBar`, which sits in the outer VStack — so the grid's ScrollView was no
/// longer the detail column's top scroll view and the unified toolbar lost its top inset for
/// the whole window (sidebar included). The fix mounts the header like the chips bar.
///
/// These tests host `RootView` in an off-screen, toolbar-shaped window (like `ClickProbeWindow`)
/// and inspect the sidebar's `NSScrollView` geometry. No synthetic clicks; never a Menu.
@MainActor
@Suite(.serialized)
struct SidebarScrollTests {

    /// Every `NSScrollView` under a view.
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
            let f = sv.convert(sv.bounds, to: nil)   // window coordinates
            return f.minX < 60 && f.maxX < 380 && f.height > 100
        }
        return try #require(leading.max(by: { $0.frame.height < $1.frame.height }),
                            "no sidebar scroll view found")
    }

    private func host(_ selection: SidebarSelection,
                      source: PreviewLibraryDataSource = .large) -> (ClickProbeWindow, LibraryViewModel) {
        let vm = LibraryViewModel(dataSource: source, selection: selection)
        let window = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 500),
                                      size: NSSize(width: 900, height: 500))
        return (window, vm)
    }

    @Test(.timeLimit(.minutes(2)))
    func sidebarIsOneScrollableListNotClippedByAnOversizedFrame() async throws {
        let (probe, _) = host(.all)
        defer { probe.close() }
        try await probe.settle()

        let sv = try sidebarScrollView(probe.window)
        // (a) The list has a document (many rows) taller than its visible height ⇒ scrollable.
        let doc = try #require(sv.documentView)
        #expect(doc.frame.height > sv.contentView.bounds.height,
                "sidebar content should be taller than the viewport at 500 pt (scrollable)")
        // (d) The sidebar did not grow past its container: its scroll view fits the window.
        let f = sv.convert(sv.bounds, to: nil)
        #expect(f.height <= probe.window.frame.height + 1)

        // (c) The top is reachable: scroll the clip to the top and the origin lands there.
        sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top))
        sv.reflectScrolledClipView(sv.contentView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sv.documentVisibleRect.minY <= 1,
                "the first sidebar rows must be reachable by scrolling to the top")
    }

    @Test(.timeLimit(.minutes(2)))
    func bundlesToExpandSidebarGeometryMatchesUnlinked() async throws {
        // Entering Bundles to Expand must leave the sidebar's scroll geometry identical to any
        // other library selection (the bug shifted it under the title bar for Bundles only).
        let (w1, _) = host(.unlinked)
        defer { w1.close() }
        try await w1.settle()
        let unlinked = try sidebarScrollView(w1.window)
        let unlinkedFrame = unlinked.convert(unlinked.bounds, to: nil)
        let unlinkedInsetTop = unlinked.contentInsets.top

        let (w2, _) = host(.bundlesToExpand)
        defer { w2.close() }
        try await w2.settle()
        let bundles = try sidebarScrollView(w2.window)
        let bundlesFrame = bundles.convert(bundles.bounds, to: nil)
        let bundlesInsetTop = bundles.contentInsets.top

        #expect(abs(unlinkedFrame.minY - bundlesFrame.minY) < 1,
                "sidebar top shifted when entering Bundles to Expand (unlinked \(unlinkedFrame) vs bundles \(bundlesFrame))")
        #expect(abs(unlinkedFrame.maxY - bundlesFrame.maxY) < 1)
        #expect(abs(unlinkedInsetTop - bundlesInsetTop) < 1,
                "sidebar top content inset differs for Bundles (\(bundlesInsetTop)) vs Unlinked (\(unlinkedInsetTop))")

        // The first rows are reachable at the top in both.
        for sv in [unlinked, bundles] {
            sv.contentView.scroll(to: NSPoint(x: 0, y: -sv.contentInsets.top))
            sv.reflectScrolledClipView(sv.contentView)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(unlinked.documentVisibleRect.minY <= 1)
        #expect(bundles.documentVisibleRect.minY <= 1)
    }
}
