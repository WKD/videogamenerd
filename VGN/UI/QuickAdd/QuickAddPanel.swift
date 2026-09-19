import AppKit
import SwiftUI

/// Presents the Quick Add palette in a floating `NSPanel` (PLAN §6.1 "Spotlight-style
/// palette, keyboard only").
///
/// **Why a panel, not a SwiftUI `.sheet`/overlay:** the palette must own the
/// keyboard completely — the text field keeps focus for typing while Tab cycles the
/// platform (not focus), ↑↓ move the selection (not the caret), and ⌘O·P·D / ⌃S…F /
/// ↩ / ⌘↩ / esc all fire regardless of the main window's SwiftUI focus system. A
/// borderless key `NSPanel` with a dedicated `NSEvent` local monitor gives exact,
/// first-responder-independent control of every key on macOS 15, which a sheet
/// (Tab moves focus, arrows move the caret, shortcuts fight the menu) does not.
@MainActor
final class QuickAddPanelController {
    private let model: QuickAddModel
    private let coverLoader: any CoverLoading
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    /// Called after the panel closes so the app can reset `quickAddPresented`.
    var onClose: () -> Void = {}

    /// Distance of the panel's top edge below the top of the active screen.
    private let topInset: CGFloat = 140

    init(model: QuickAddModel, coverLoader: any CoverLoading) {
        self.model = model
        self.coverLoader = coverLoader
        model.onRequestClose = { [weak self] in self?.hide() }
    }

    // MARK: - Show / hide

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionTopCenter(panel)
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
        onClose()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - Panel

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: QuickAddView(model: model, coverLoader: coverLoader))
        hosting.sizingOptions = [.preferredContentSize]
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 200),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        // So the on-demand UI smoke suite can find and window-screenshot the
        // floating palette (its own app window, never the owner's).
        panel.setAccessibilityIdentifier(A11yID.quickAddPanel)
        panel.delegate = panelDelegate
        // Keep the top edge pinned as the content grows/shrinks with the results.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repin() }
        }
        return panel
    }

    private lazy var panelDelegate = QuickAddPanelDelegate { [weak self] in self?.hide() }

    private func positionTopCenter(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let x = screen.visibleFrame.midX - frame.width / 2
        let topY = screen.visibleFrame.maxY - topInset
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: topY))
        lastTopLeft = NSPoint(x: x, y: topY)
    }

    private var lastTopLeft: NSPoint = .zero
    private func repin() {
        guard let panel else { return }
        panel.setFrameTopLeftPoint(lastTopLeft)
    }

    // MARK: - Key monitor (AppKit owns every palette key)

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Route one key event to the model. Returns true when it was consumed (so the
    /// text field never sees it); false lets it through for normal typing.
    private func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = mods.contains(.command)
        let hasControl = mods.contains(.control)
        let onlyPlain = mods.subtracting([.shift, .function, .numericPad]).isEmpty

        switch event.keyCode {
        case 36, 76:                                   // Return / keypad Enter
            // ↩ add (field clears) · ⇧↩ add and keep the list (series) · ⌘↩ add & open
            model.commit(openInspector: hasCommand, keepResults: mods.contains(.shift))
            return true
        case 53:                                        // Escape
            if !model.handleEscape() { hide() }
            return true
        case 125:                                        // Down arrow
            if onlyPlain { model.moveSelection(by: 1); return true }
        case 126:                                        // Up arrow
            if onlyPlain { model.moveSelection(by: -1); return true }
        case 48:                                          // Tab (⇧Tab reverses)
            if mods.subtracting(.shift).isEmpty {
                model.cyclePlatform(by: mods.contains(.shift) ? -1 : 1)
                return true
            }
        default:
            break
        }

        // ⌘O / ⌘P — owned / played · ⌘D cycles the copy format · ⌘1 ⌘2 ⌘3 pick it
        if hasCommand, let ch = event.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "o": model.toggleOwned(); return true
            case "p": model.togglePlayed(); return true
            case "d": model.cycleFormat(); return true
            case "1": model.setFormat(.physical); return true
            case "2": model.setFormat(.digital); return true
            case "3": model.setFormat(.rom); return true
            default: break
            }
        }
        // ⌃S…⌃F set the tier, ⌃0 clears it
        if hasControl, let ch = event.charactersIgnoringModifiers?.uppercased() {
            if ["S", "A", "B", "C", "D", "F"].contains(ch) { model.setTier(ch); return true }
            if ch == "0" { model.setTier(nil); return true }
        }
        return false
    }
}

/// A borderless panel that can still become key (needed for the text field to take
/// focus and for the key monitor to be `isKeyWindow`).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Closes the palette when it loses key (click elsewhere / app switch).
private final class QuickAddPanelDelegate: NSObject, NSWindowDelegate {
    let onResignKey: () -> Void
    init(onResignKey: @escaping () -> Void) { self.onResignKey = onResignKey }
    func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { onResignKey() }
    }
}
