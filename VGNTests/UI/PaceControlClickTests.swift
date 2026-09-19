import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks against the "By Length" pace control (PLAN §8), using the shared
/// `ClickProbeWindow`. The section-header button opens a popover (its own window), so
/// per the brief the popover content (`PaceEditor`) is hosted directly and its Reset
/// button is clicked; the header button's own clickability is checked separately.
@MainActor
@Suite(.serialized)
struct PaceControlClickTests {

    private final class ClickBox { var clicked = false }

    @Test(.timeLimit(.minutes(5)))
    func paceHeaderButtonReceivesClicks() async throws {
        let box = ClickBox()
        let header = VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BY LENGTH")
                Spacer()
                PaceHeaderButton(label: "8 h / week", isCTA: false) { box.clicked = true }
            }
            .padding(10)
            Color.clear
        }
        let window = ClickProbeWindow(header.frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()

        _ = try await window.sweep(band: 80, stepX: 8, stepY: 6, rightToLeft: true) {
            box.clicked ? 1 : 0
        } until: { box.clicked }
        #expect(box.clicked, "no click reached the pace header button")
    }

    @Test(.timeLimit(.minutes(5)))
    func popoverResetButtonReceivesClicks() async throws {
        // Start from a non-default pace so Reset is enabled and its effect is visible.
        let model = PlayPaceModel(store: InMemoryPlayPacePreferences(pace: PlayPace(hoursPerWeek: 2), chosen: true))
        let editor = PaceEditor(model: model).padding(16).frame(width: 300)
        let window = ClickProbeWindow(editor.frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()

        // Sweep a tall band so the Reset row (bottom of the editor) is reached.
        _ = try await window.sweep(band: 360, stepX: 10, stepY: 8) {
            Int(model.pace.hoursPerWeek.rounded())
        } until: { model.pace.hoursPerWeek == PlayPace.default.hoursPerWeek && model.pace.hoursPerWeek != 2 }
        #expect(model.pace.hoursPerWeek == 8, "Reset did not commit 8 h (pace = \(model.pace.hoursPerWeek))")
    }
}
