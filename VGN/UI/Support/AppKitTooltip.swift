import AppKit
import SwiftUI

/// A tooltip that always shows. SwiftUI's `.help` proved unreliable on macOS for
/// views inside plain-style buttons, overlays and the inspector column (owner reports,
/// 2026-09-19), and it cannot be verified headless. This attaches a real AppKit
/// `toolTip` through a transparent overlay that is invisible to hit-testing — clicks,
/// drags and hovers reach the SwiftUI view underneath, while AppKit's tooltip tracking
/// (which works on the view's bounds, not on hit-testing) still fires. Tests can find
/// it by walking the `NSView` tree for `toolTip`.
extension View {
    /// Shows `text` on hover (nothing when empty) and exposes it as the accessibility hint.
    func appKitTooltip(_ text: String) -> some View {
        // The overlay is hidden from accessibility: the text is already the view's
        // hint, and an NSView inside an `.accessibilityElement(children: .combine)`
        // parent (a grid cell's tier chip) turned the combined element into an
        // AXUnknown with NO value — XCUITest/VoiceOver lost the cell's "Tier A,
        // Played" state (found by the UI smoke suite, wave 22).
        overlay { AppKitTooltipOverlay(text: text).accessibilityHidden(true) }
            .accessibilityHint(Text(text))
    }
}

private struct AppKitTooltipOverlay: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipPassthroughView {
        let view = TooltipPassthroughView()
        view.toolTip = text.isEmpty ? nil : text
        return view
    }

    func updateNSView(_ view: TooltipPassthroughView, context: Context) {
        let new: String? = text.isEmpty ? nil : text
        if view.toolTip != new { view.toolTip = new }
    }
}

/// Never the target of a mouse event; exists only to carry a `toolTip`.
final class TooltipPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilityElement() -> Bool { false }
}
