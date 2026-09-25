import AppKit
import SwiftUI

/// The main library `WindowGroup`'s scene id (so `openWindow(id:)` can reach it).
enum MainWindowID {
    static let id = "library"
}

/// Guarantees the main library window exists after launch (wave 23, bug "no window
/// when launched in the background").
///
/// Root cause: when the app is launched without being activated (`open -g`, a login
/// item, XCUITest's `launch()`), AppKit finds saved state to restore
/// (`hasPersistentStateToRestore`), asks SwiftUI's restorer for the main window, the
/// restorer hands back `nil` — and because a restoration *ran*, SwiftUI does not open
/// its default `WindowGroup` window either. The app comes up with a menu bar and no
/// window until the Dock icon is clicked.
///
/// Fix: every main window registers itself here (``MainWindowMarker``). Shortly after
/// launch — and again on the first activation — if no registered main window is on
/// screen (visible or minimised), the guard opens one through the scene's
/// `openWindow(id:)`. It never opens a second window when restoration did work: the
/// restored window registers itself first, and absence has to be confirmed twice,
/// one beat apart, before anything is opened. Window-frame persistence is untouched
/// (state restoration stays on).
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

    /// Set by ``MainWindowCommands`` (commands are built at launch even when no
    /// window exists, so `openWindow` is reachable from there).
    var openMainWindow: (() -> Void)?

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
            self.openMainWindow?()
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

/// Hands the main scene's `openWindow` to ``MainWindowGuard``. Adds no menu items.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let open = openWindow
        MainWindowGuard.shared.openMainWindow = { open(id: MainWindowID.id) }
        return EmptyCommands()
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
