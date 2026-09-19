import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Tooltips that can be verified headless: `appKitTooltip` puts a real AppKit
/// `toolTip` over the view without stealing its clicks (owner reports 2026-09-19: the
/// tier tooltip never showed in the inspector with SwiftUI's `.help`).
@MainActor
@Suite(.serialized)
struct AppKitTooltipTests {
    @MainActor final class Counter { var clicks = 0 }

    private func tooltips(in view: NSView, into out: inout [(String, NSRect)]) {
        if let tip = view.toolTip, !tip.isEmpty { out.append((tip, view.convert(view.bounds, to: nil))) }
        for sub in view.subviews { tooltips(in: sub, into: &out) }
    }

    private func allTooltips(_ window: ClickProbeWindow) -> [(String, NSRect)] {
        var found: [(String, NSRect)] = []
        if let root = window.window.contentView { tooltips(in: root, into: &found) }
        return found
    }

    @Test(.timeLimit(.minutes(2)))
    func tierChipCarriesItsLabelAndScore() async throws {
        let view = HStack {
            TierChip(letter: "S", colorHex: "#FF7F7F", size: 26, label: "Masterpiece",
                     score: DerivedScoreValue(value: 9.4, isApproximate: false))
            TierChip(letter: "A", colorHex: "#FFBF7F", size: 26)                  // label from the environment
            TierChip(letter: "B", colorHex: "#FFDF7F", size: 26, showsLabelOnHover: false)
        }.padding(40)
        let window = ClickProbeWindow(view.frame(width: 400, height: 200), size: NSSize(width: 400, height: 200))
        defer { window.close() }
        try await window.settle()
        let tips = allTooltips(window).map(\.0)
        #expect(tips.contains { $0.hasPrefix("S — Masterpiece · 9") })
        #expect(tips.contains("A — Excellent"))
        #expect(!tips.contains { $0.hasPrefix("B") })
    }

    @Test(.timeLimit(.minutes(2)))
    func theTooltipOverlayDoesNotStealClicks() async throws {
        let counter = Counter()
        let view = VStack {
            Button { counter.clicks += 1 } label: {
                TierChip(letter: "S", colorHex: "#FF7F7F", size: 40, showsLabelOnHover: false)
            }
            .buttonStyle(.plain)
            .appKitTooltip("S — Masterpiece")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        let window = ClickProbeWindow(view.frame(width: 300, height: 200), size: NSSize(width: 300, height: 200))
        defer { window.close() }
        try await window.settle()
        let tip = try #require(allTooltips(window).first { $0.0 == "S — Masterpiece" })
        #expect(tip.1.width >= 30 && tip.1.height >= 30, "the tooltip must cover the chip")
        window.click(at: NSPoint(x: tip.1.midX, y: tip.1.midY))
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.clicks == 1, "the click must reach the button under the tooltip overlay")
    }
}
