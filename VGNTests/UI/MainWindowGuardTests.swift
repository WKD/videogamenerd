import Testing
@testable import VGN

/// Wave 23 — "no window when launched in the background": the pure decision behind
/// ``MainWindowGuard`` (open a main window only when none is on screen or minimised).
struct MainWindowGuardTests {
    typealias W = MainWindowGuard.WindowState

    @Test func noRegisteredWindowNeedsOne() {
        #expect(MainWindowGuard.needsMainWindow(windows: [], appIsHidden: false, isUnitTestHost: false))
    }

    @Test func onlyClosedWindowsNeedOne() {
        let closed = W(isVisible: false, isMiniaturized: false)
        #expect(MainWindowGuard.needsMainWindow(windows: [closed, closed], appIsHidden: false, isUnitTestHost: false))
    }

    @Test func restoredVisibleWindowIsNeverDoubled() {
        let windows = [W(isVisible: false, isMiniaturized: false), W(isVisible: true, isMiniaturized: false)]
        #expect(!MainWindowGuard.needsMainWindow(windows: windows, appIsHidden: false, isUnitTestHost: false))
    }

    @Test func minimisedWindowCounts() {
        let windows = [W(isVisible: false, isMiniaturized: true)]
        #expect(!MainWindowGuard.needsMainWindow(windows: windows, appIsHidden: false, isUnitTestHost: false))
    }

    @Test func hiddenAppIsLeftAlone() {
        #expect(!MainWindowGuard.needsMainWindow(windows: [], appIsHidden: true, isUnitTestHost: false))
    }

    @Test func unitTestHostIsLeftAlone() {
        #expect(!MainWindowGuard.needsMainWindow(windows: [], appIsHidden: false, isUnitTestHost: true))
    }
}
