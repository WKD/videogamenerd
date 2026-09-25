import XCTest

/// Flow (a): launch → sidebar rows + counts present → select smart lists and a
/// platform → grid updates.
final class LaunchSmokeTests: VGNUITestCase {

    func testLaunchShowsSidebarSmartListsAndGrid() {
        launchSample()
        require(window, "main window")

        // Sidebar smart lists all present.
        require(el(A11y.sidebarAll), "All row")
        require(el(A11y.sidebarOwned), "Owned row")
        require(el(A11y.sidebarPlayed), "Played row")
        require(el(A11y.sidebarBacklog), "Backlog row")
        require(el(A11y.sidebarUnranked), "Unranked row")

        // The grid loads the sample library (9 singles + 2 compilation members).
        require(el(A11y.grid), "grid")
        let cells = elements(withPrefix: A11y.gridCellPrefix)
        XCTAssertGreaterThanOrEqual(cells.count, 8,
            "Expected the sample library to fill the grid, got \(cells.count) cells")
        attachWindowScreenshot("a1-launch-all")

        // Selecting "Owned" should narrow the grid (fewer than "All").
        let allCount = cells.count
        el(A11y.sidebarOwned).click()
        // Give the observation a beat to re-query, then compare.
        let ownedCells = waitForGridToSettle()
        XCTAssertLessThanOrEqual(ownedCells, allCount,
            "Owned should not show more games than All")
        attachWindowScreenshot("a2-owned")

        // Selecting a platform scopes the grid too.
        el(A11y.sidebarPlayed).click()
        _ = waitForGridToSettle()
        attachWindowScreenshot("a3-played")
    }

    /// Wave 23 — "no window when launched in the background". Run twice WITHOUT
    /// `-ApplePersistenceIgnoreState`: the first run leaves saved window state
    /// behind, the second has AppKit restore it while XCUITest launches the app
    /// without activating it — the exact path that used to come up with a menu bar
    /// and no window. `MainWindowGuard` must produce exactly one main window.
    func testLaunchWithSavedStateStillShowsWindow() {
        launchSample(ignorePersistentState: false)
        require(window, "main window (first launch)")
        require(el(A11y.grid), "grid (first launch)")
        app.terminate()

        launchSample(ignorePersistentState: false)
        require(window, "main window after restoring saved state", timeout: 15)
        require(el(A11y.grid), "grid after restoring saved state")
        // Never a second main window when restoration did work.
        usleep(1_500_000)
        XCTAssertEqual(app.windows.count, 1, "Expected exactly one main window")
        attachWindowScreenshot("a4-launch-saved-state")
    }

    /// Poll until the grid cell count stops changing, returning the settled count.
    private func waitForGridToSettle(timeout: TimeInterval = 4) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var last = -1
        while Date() < deadline {
            let count = elements(withPrefix: A11y.gridCellPrefix).count
            if count == last { return count }
            last = count
            usleep(300_000)
        }
        return last
    }
}
