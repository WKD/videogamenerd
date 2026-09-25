import AppKit
import OSLog
import SwiftUI

private let guardLog = Logger(subsystem: "com.pomatelier.VideoGameNerd", category: "MainWindowGuard")

/// The main library `WindowGroup`'s scene id — also its stable state-restoration identifier
/// (`library-AppWindow-1`), which no longer changes when the root view's modifiers do.
enum MainWindowID {
    static let id = "library"
}

/// Guarantees the main library window exists after launch (wave 23, bug "no window
/// when launched in the background").
///
/// Root cause (confirmed from the app's `StateRestoration` log, wave 23): AppKit
/// restores the saved main window by its identifier. An id-less `WindowGroup`'s
/// identifier was the **type name of its root view's modifier chain**
/// (`SwiftUI._ConditionalContent<…RootView…>-1-AppWindow-1`), which changes whenever a
/// build adds/removes a modifier there. After such a build SwiftUI's restorer cannot map
/// the saved identifier to a scene and returns `window=0x0`, and because a restoration
/// *ran*, SwiftUI opens no default window either. A launch that activates the app gets
/// one anyway; a background launch (`open -g`, a login item, XCUITest) comes up with a
/// menu bar and no window until the Dock icon is clicked.
///
/// Fix, two parts: (1) the main `WindowGroup` has a stable id (``MainWindowID``), so
/// its saved identifier (`library-AppWindow-1`) survives rebuilds; (2) this guard, for
/// state saved by an older build (or any other miss): every main window registers
/// itself (``MainWindowMarker``); shortly after launch — and again on the first
/// activation — if no registered main window is visible or minimised (confirmed twice,
/// one beat apart, so a restored window is never doubled) it asks SwiftUI's own
/// application delegate to open an untitled window (`applicationOpenUntitledFile(_:)`
/// — what SwiftUI uses for its default window). NOTE: `openWindow` captured from the
/// scene's `Commands` does NOT work here — with no window SwiftUI has not evaluated the
/// commands yet (the first version of this fix relied on it and opened nothing).
/// Window-frame persistence is untouched (state restoration stays on).
@MainActor
final class MainWindowGuard {
    static let shared = MainWindowGuard()

    /// What the decision looks at for one registered main window.
    struct WindowState: Equatable, Sendable {
        var isVisible: Bool
        var isMiniaturized: Bool
    }

    /// Pure decision: open a main window only when none is on screen or in the Dock,
    /// the app isn't hidden (a hidden app keeps its windows off screen on purpose),
    /// and the process is not a unit-test host (which renders a placeholder window).
    nonisolated static func needsMainWindow(
        windows: [WindowState],
        appIsHidden: Bool,
        isUnitTestHost: Bool
    ) -> Bool {
        if isUnitTestHost || appIsHidden { return false }
        return !windows.contains { $0.isVisible || $0.isMiniaturized }
    }

    /// Opens a main window. Default: SwiftUI's application delegate's
    /// `applicationOpenUntitledFile(_:)` (injectable for tests).
    var openMainWindow: @MainActor () -> Void = MainWindowGuard.openUntitledWindow

    /// Ask SwiftUI's own `NSApplicationDelegate` for an untitled (default) window.
    static func openUntitledWindow() {
        guard let app = NSApp, let delegate = app.delegate else { return }
        let opened = delegate.applicationOpenUntitledFile?(app) ?? false
        guardLog.notice("no main window after launch — opened one: \(opened)")
    }

    private let windows = NSHashTable<NSWindow>.weakObjects()
    private var didCheckOnActivation = false
    private var checkScheduled = false

    /// Called by ``MainWindowMarker`` when a main window's content lands in a window.
    func register(_ window: NSWindow) {
        windows.add(window)
    }

    private var currentStates: [WindowState] {
        windows.allObjects.map {
            WindowState(isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized)
        }
    }

    private var needsWindowNow: Bool {
        Self.needsMainWindow(
            windows: currentStates,
            appIsHidden: NSApp?.isHidden ?? false,
            isUnitTestHost: VGNApp.isRunningUnitTests
        )
    }

    /// Launch hook: let AppKit restoration / SwiftUI's default window settle, then
    /// check.
    func applicationDidFinishLaunching() {
        scheduleCheck()
    }

    /// First activation (e.g. the owner clicks the app after a background launch).
    func applicationDidBecomeActive() {
        guard !didCheckOnActivation else { return }
        didCheckOnActivation = true
        scheduleCheck()
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        Task { @MainActor [weak self] in
            // Absence must hold on two looks one beat apart, so a window that is
            // still being restored/created is never doubled.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            guard self.needsWindowNow else { self.checkScheduled = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            self.checkScheduled = false
            guard self.needsWindowNow else { return }
            self.openMainWindow()
        }
    }
}

/// Invisible view placed in every main window: registers its hosting `NSWindow`
/// with ``MainWindowGuard``.
struct MainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}

    final class MarkerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindowGuard.shared.register(window) }
        }
    }
}

/// The app delegate adaptor: forwards the launch / activation hooks to the guard.
/// SwiftUI keeps its own delegate and forwards anything not implemented here.
final class VGNAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainWindowGuard.shared.applicationDidFinishLaunching()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainWindowGuard.shared.applicationDidBecomeActive()
    }
}
