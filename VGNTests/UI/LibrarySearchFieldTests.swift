import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The toolbar search field has a working clear button (owner request 2026-09-19).
@MainActor
@Suite(.serialized)
struct LibrarySearchFieldTests {
    @MainActor @Observable final class Box { var text = "zelda"; var cleared = 0 }

    private struct Harness: View {
        @Bindable var box: Box
        @FocusState private var focused: Bool
        var body: some View {
            VStack {
                LibrarySearchField(text: $box.text, focus: $focused,
                                   onClear: { box.text = ""; box.cleared += 1 },
                                   onDownArrow: {}, onEscape: {}, onSubmit: {})
                    .frame(width: 220)
                Spacer()
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func theClearButtonAppearsWithTextAndClearsIt() async throws {
        let box = Box()
        let window = ClickProbeWindow(Harness(box: box).frame(width: 500, height: 300), size: NSSize(width: 500, height: 300))
        defer { window.close() }
        try await window.settle()

        // The button carries an AppKit tooltip → find it, click its centre.
        var tips: [(String, NSRect)] = []
        func walk(_ v: NSView) { if let t = v.toolTip, !t.isEmpty { tips.append((t, v.convert(v.bounds, to: nil))) }; v.subviews.forEach(walk) }
        if let root = window.window.contentView { walk(root) }
        let clear = try #require(tips.first { $0.0.hasPrefix("Clear search") })
        window.click(at: NSPoint(x: clear.1.midX, y: clear.1.midY))
        try await Task.sleep(for: .milliseconds(300))
        #expect(box.text.isEmpty)
        #expect(box.cleared == 1)

        // With no text the button is gone.
        tips = []
        if let root = window.window.contentView { walk(root) }
        #expect(!tips.contains { $0.0.hasPrefix("Clear search") })
    }
}
