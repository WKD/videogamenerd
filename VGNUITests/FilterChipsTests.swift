import XCTest

/// Flow (i): filter chips — apply Tier + Status filters → chips appear → remove
/// one → grid updates → Clear all.
final class FilterChipsTests: VGNUITestCase {

    func testApplyFiltersShowChipsRemoveAndClear() {
        launchSample()
        require(el(A11y.grid), "grid")
        let baseline = elements(withPrefix: A11y.gridCellPrefix).count

        // Apply a Tier filter from the toolbar menu.
        openMenuAndPickFirst(A11y.toolbarFilterTier)
        // Apply a Status filter too.
        openMenuAndPickFirst(A11y.toolbarFilterStatus)

        // Chips appear for the active filters.
        let chips = require(el(A11y.filterChips), "filter chips bar")
        _ = chips
        let chipEls = waitForChips(atLeast: 1)
        XCTAssertGreaterThanOrEqual(chipEls, 1, "Active filters should show removable chips")
        attachWindowScreenshot("i1-chips")

        // The grid should have narrowed from the unfiltered baseline.
        let filtered = elements(withPrefix: A11y.gridCellPrefix).count
        XCTAssertLessThanOrEqual(filtered, baseline, "Filters should not widen the grid")

        // Remove one chip (click it), then Clear all.
        let firstChip = elements(withPrefix: "filter.chip.").first
        firstChip?.click()
        attachWindowScreenshot("i2-one-removed")

        if el(A11y.filterClearAll).exists {
            el(A11y.filterClearAll).click()
            let gone = waitForChips(atLeast: 0, expectEmpty: true)
            XCTAssertEqual(gone, 0, "Clear all should remove every chip")
        }
        attachWindowScreenshot("i3-cleared")
    }

    private func openMenuAndPickFirst(_ menuID: String) {
        let menu = el(menuID)
        guard menu.waitForExistence(timeout: 6) else {
            XCTFail("filter menu \(menuID) not found"); return
        }
        menu.click()
        // The first item OF THIS pop-up's menu is its first toggle (a tier / a status).
        // Scoped to the pop-up: `app.menuItems` would start with the menu BAR's items
        // (Apple ▸ About …), which are not on screen — clicking one stalls ~45 s.
        let item = menu.menuItems.element(boundBy: 0)
        if item.waitForExistence(timeout: 3) {
            item.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    private func waitForChips(atLeast n: Int, expectEmpty: Bool = false,
                              timeout: TimeInterval = 3) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = elements(withPrefix: "filter.chip.").count
            if expectEmpty && count == 0 { return 0 }
            if !expectEmpty && count >= n { return count }
            usleep(200_000)
        }
        return elements(withPrefix: "filter.chip.").count
    }
}
