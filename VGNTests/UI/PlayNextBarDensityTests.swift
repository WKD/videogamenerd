import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The Play Next bar drops its button labels (then the segmented picker) when the
/// window is narrow, instead of overflowing and making the layout wiggle
/// (owner report 2026-09-19).
@MainActor
@Suite(.serialized)
struct PlayNextBarDensityTests {
    private func tooltips(width: CGFloat) async throws -> [(String, NSRect)] {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult())
        let view = VStack(spacing: 0) { PlayNextBracketBar(model: model); Spacer() }
            .frame(width: width, height: 300)
        let window = ClickProbeWindow(view, size: NSSize(width: width, height: 300))
        defer { window.close() }
        try await window.settle()
        var tips: [(String, NSRect)] = []
        func walk(_ v: NSView) { if let t = v.toolTip, !t.isEmpty { tips.append((t, v.convert(v.bounds, to: nil))) }; v.subviews.forEach(walk) }
        if let root = window.window.contentView { walk(root) }
        return tips
    }

    private func askClaudeRect(width: CGFloat) async throws -> NSRect {
        try #require(try await tooltips(width: width).first { $0.0.hasPrefix("Ask Claude") }).1
    }

    @Test(.timeLimit(.minutes(3)))
    func theBarAlwaysFitsAndShedsLabelsWhenNarrow() async throws {
        let wide = try await askClaudeRect(width: 1100)
        let medium = try await askClaudeRect(width: 640)
        let narrow = try await askClaudeRect(width: 440)

        // Always fully inside the window (20 pt padding each side). The six "By Length"
        // segments are wider than the old four, so 440 pt falls back to the menu picker.
        for (rect, width) in [(wide, 1100.0), (medium, 640.0), (narrow, 440.0)] {
            #expect(rect.minX >= 0 && rect.maxX <= width, "Ask Claude must stay inside a \(Int(width)) pt window: \(rect)")
        }
        // Wide shows the label; narrower widths are icon-only (a much narrower button).
        #expect(wide.width > 80)
        #expect(medium.width < wide.width - 30)
        #expect(narrow.width <= medium.width + 1)
    }

    /// The bracket picker carries its shelf/range tooltip at every density (so the new
    /// six-segment control renders in full, icon-button and compact-menu layouts).
    @Test(.timeLimit(.minutes(3)))
    func bracketRangeTooltipPresentAtEveryDensity() async throws {
        for width in [1100.0, 640.0, 440.0] {
            let tips = try await tooltips(width: width)
            #expect(tips.contains { $0.0.contains("a week") },
                    "the bracket range tooltip should be present at \(Int(width)) pt")
        }
    }
}
