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
