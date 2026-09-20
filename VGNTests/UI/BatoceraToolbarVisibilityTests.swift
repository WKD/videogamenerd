import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The grid toolbar (search, filter menus, sort, size slider) shows only on a library grid
/// destination (D1, PLAN §8): a ranking view, Play Next and the Vault browser have their own
/// controls, so those toolbar items were dead there. Hiding them is toolbar-only and must not
/// move the sidebar / safe-area geometry.
@MainActor
@Suite(.serialized)
struct BatoceraToolbarVisibilityTests {

    // MARK: - The model rule (definitive: which selections hide the grid controls)

    @Test func gridDestinationsShowTheToolbarNonGridOnesDoNot() {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)

        for selection: SidebarSelection in [.all, .owned, .played, .backlog, .unranked,
                                            .unlinked, .bundlesToExpand, .unmeasured,
                                            .platform("snes")] {
            vm.select(selection)
            #expect(vm.showsGridToolbar, "\(selection.id) is a grid destination")
        }
        for selection: SidebarSelection in [.playNext, .tierBoard, .theTop, .duel,
                                            .vault(.batocera), .vault(.psn)] {
            vm.select(selection)
            #expect(!vm.showsGridToolbar, "\(selection.id) has its own controls — no grid toolbar")
        }
    }

    // MARK: - The hosted window (toolbar item delta + sidebar geometry unchanged)

    @Test(.timeLimit(.minutes(5)))
    func vaultHasFewerToolbarItemsAndTheSidebarDoesNotMove() async throws {
        let allVM = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        allVM.select(.all)
        let allWindow = ClickProbeWindow(RootView(vm: allVM).frame(minWidth: 900, minHeight: 600))
        defer { allWindow.close() }
        try await allWindow.settle()

        let vaultVM = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        vaultVM.select(.vault(.batocera))
        let vaultWindow = ClickProbeWindow(RootView(vm: vaultVM).frame(minWidth: 900, minHeight: 600))
        defer { vaultWindow.close() }
        try await vaultWindow.settle()

        // The toolbar bridges over run-loop turns; poll until both windows have it before counting.
        await allWindow.poll { (allWindow.window.toolbar?.items.count ?? 0) > 0 }
        await vaultWindow.poll { (vaultWindow.window.toolbar?.items.count ?? 0) > 0 }

        let allItems = allWindow.window.toolbar?.items.count ?? 0
        let vaultItems = vaultWindow.window.toolbar?.items.count ?? 0
        #expect(allItems > vaultItems, "the grid toolbar (search/filters/sort/size) is dropped in the Vault (\(allItems) vs \(vaultItems))")
        #expect(vaultItems > 0, "the app-level buttons (Inspector, Add) still show in the Vault")

        // Changing the toolbar must not shift the sidebar (the header-above-grid geometry bug family).
        let allSidebar = try #require(Self.leftmostScrollFrame(in: allWindow.window))
        let vaultSidebar = try #require(Self.leftmostScrollFrame(in: vaultWindow.window))
        #expect(abs(allSidebar.minX - vaultSidebar.minX) < 0.5)
        #expect(abs(allSidebar.width - vaultSidebar.width) < 0.5)
        #expect(abs(allSidebar.minY - vaultSidebar.minY) < 0.5)
        #expect(abs(allSidebar.height - vaultSidebar.height) < 0.5)
    }

    /// The frame (window coordinates) of the left-most `NSScrollView` — the sidebar's list.
    private static func leftmostScrollFrame(in window: NSWindow) -> CGRect? {
        guard let content = window.contentView else { return nil }
        var scrolls: [NSScrollView] = []
        collectScrollViews(in: content, into: &scrolls)
        guard let sidebar = scrolls.min(by: { frame($0, in: window).minX < frame($1, in: window).minX })
        else { return nil }
        return frame(sidebar, in: window)
    }

    private static func frame(_ view: NSView, in window: NSWindow) -> CGRect {
        view.convert(view.bounds, to: nil)
    }

    private static func collectScrollViews(in view: NSView, into out: inout [NSScrollView]) {
        if let scroll = view as? NSScrollView { out.append(scroll) }
        for sub in view.subviews { collectScrollViews(in: sub, into: &out) }
    }
}
