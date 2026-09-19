import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse events against a window shaped like the app's (unified toolbar,
/// full-size content), kept off-screen and never made key.
///
/// Owner bug 2026-09-19: the filter chips' ✕ and "Clear all" did nothing. The model
/// was right; the chips sat in a horizontal `ScrollView` whose top edge touched the
/// window toolbar, and in that position macOS delivers clicks to the scroll view's
/// clip view instead of the SwiftUI buttons. Model-level tests cannot see that —
/// this one clicks.
@MainActor
@Suite(.serialized)
struct FilterChipsClickTests {
    private func makeVM() -> LibraryViewModel {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        var f = LibraryFilter(scope: .all)
        f.genres = ["RPG"]
        f.includeNotPlayed = true
        vm.setFilter(f)
        return vm
    }

    @Test(.timeLimit(.minutes(5)))
    func chipRemoveButtonsAndClearAllReceiveClicksUnderTheToolbar() async throws {
        let vm = makeVM()
        #expect(vm.filterChips.count == 2)
        let window = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        #expect(window.hasToolbar, "the probe must reproduce the real window: a bridged toolbar")

        // Sweep the band just under the toolbar; every click that lands on a ✕ (or on
        // "Clear all") removes chips.
        let removed = try await window.sweep(band: 40, stepX: 10, stepY: 6) { vm.filterChips.count } until: { vm.filterChips.isEmpty }
        #expect(removed >= 1, "no click reached the chips bar")
        #expect(vm.filterChips.isEmpty)
        #expect(!vm.filter.hasActiveFacets)
    }

    @Test(.timeLimit(.minutes(5)))
    func clearAllAloneEmptiesTheFilter() async throws {
        let vm = makeVM()
        let bar = VStack(spacing: 0) { FilterChipsBar(vm: vm); Color.clear }.toolbar { Button("X") {} }
        let window = ClickProbeWindow(bar.frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        // Sweep right-to-left so "Clear all" (after the chips) is reached first.
        _ = try await window.sweep(band: 40, stepX: 10, stepY: 6, rightToLeft: true) { vm.filterChips.count } until: { vm.filterChips.isEmpty }
        #expect(vm.filterChips.isEmpty)
    }
}

/// An off-screen window shaped like the app's main window that accepts synthetic
/// mouse clicks. Reusable for any "is this control actually clickable?" check.
@MainActor
final class ClickProbeWindow {
    let window: NSWindow

    init<V: View>(_ view: V, size: NSSize = NSSize(width: 1100, height: 700)) {
        let controller = NSHostingController(rootView: view)
        controller.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                          styleMask: [.titled, .resizable, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFrontRegardless()      // visible to AppKit, off-screen, never key
    }

    var hasToolbar: Bool { (window.toolbar?.items.count ?? 0) > 0 }
    /// Top of the content area below the toolbar, in window coordinates.
    var contentTop: CGFloat { window.contentLayoutRect.maxY }

    func settle() async throws { try await Task.sleep(for: .milliseconds(1000)) }
    func close() { window.orderOut(nil); window.close() }

    func click(at point: NSPoint) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // A button's mouse-down runs a tracking loop that pulls the mouse-up from the
        // queue, so the up event has to be queued first or the loop never ends.
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        window.sendEvent(event(.leftMouseDown))
    }

    /// Click a grid of points in the `band` points under the toolbar; returns how many
    /// clicks changed `observe()`. Stops as soon as `until()` is true.
    func sweep(band: CGFloat, stepX: CGFloat, stepY: CGFloat, rightToLeft: Bool = false,
               observe: () -> Int, until: () -> Bool) async throws -> Int {
        var changes = 0
        // Up to three passes, each more patient: under a loaded test run SwiftUI may
        // need longer to lay the window out and to process a click.
        for wait in [6, 15, 40] {
            let xs = Array(stride(from: CGFloat(4), through: window.frame.width - 4, by: stepX))
            for y in stride(from: contentTop - 2, through: contentTop - band, by: -stepY) {
                for x in (rightToLeft ? xs.reversed() : xs) {
                    let before = observe()
                    click(at: NSPoint(x: x, y: y))
                    try await Task.sleep(for: .milliseconds(wait))
                    if observe() != before { changes += 1 }
                    if until() { return changes }
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return changes
    }
}
