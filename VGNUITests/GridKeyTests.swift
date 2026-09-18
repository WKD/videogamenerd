import XCTest

/// Flow (c): grid keys — select a game, `A` sets tier A, `P` marks played,
/// multi-select + tier, `⌘Z` undoes.
final class GridKeyTests: VGNUITestCase {

    func testTierKeySetsTierThenUndo() {
        launchSample()
        require(el(A11y.grid), "grid")

        // Disco Elysium seeds as owned, unplayed, unranked.
        let disco = require(gridCell(titled: "Disco Elysium"), "Disco Elysium cell")
        disco.click()
        XCTAssertFalse(((disco.value as? String) ?? "").contains("Tier"),
            "Disco Elysium should start unranked")

        app.typeText("a")   // over the focused grid → tier A
        expectValue(of: "Disco Elysium", contains: "Tier A")
        attachWindowScreenshot("c1-tier-A")

        // ⌘Z undoes the tier change.
        shortcut("z", .command)
        expectValue(of: "Disco Elysium", notContains: "Tier A")
        attachWindowScreenshot("c2-undo")
    }

    func testMarkPlayedKey() {
        launchSample()
        require(el(A11y.grid), "grid")

        let disco = require(gridCell(titled: "Disco Elysium"), "Disco Elysium cell")
        disco.click()
        XCTAssertFalse(((disco.value as? String) ?? "").contains("Played"),
            "Disco Elysium should start unplayed")

        app.typeText("p")   // mark played
        expectValue(of: "Disco Elysium", contains: "Played")
        attachWindowScreenshot("c3-mark-played")
    }

    func testMultiSelectTier() {
        launchSample()
        require(el(A11y.grid), "grid")

        let disco = require(gridCell(titled: "Disco Elysium"), "Disco Elysium cell")
        disco.click()
        // Extend the selection into the next cell, then tier the set.
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeText("c")
        expectValue(of: "Disco Elysium", contains: "Tier C")
        attachWindowScreenshot("c4-multiselect-tier")
    }

    // MARK: helpers

    private func expectValue(of title: String, contains needle: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let ok = waitForValue(of: title) { $0.contains(needle) }
        XCTAssertTrue(ok, "Expected \(title)'s state to contain '\(needle)'", file: file, line: line)
    }

    private func expectValue(of title: String, notContains needle: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let ok = waitForValue(of: title) { !$0.contains(needle) }
        XCTAssertTrue(ok, "Expected \(title)'s state to no longer contain '\(needle)'",
                      file: file, line: line)
    }

    /// Poll the cell's accessibility value until `predicate` holds or we time out.
    private func waitForValue(of title: String, timeout: TimeInterval = 4,
                              _ predicate: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate((gridCell(titled: title).value as? String) ?? "") { return true }
            usleep(250_000)
        }
        return false
    }
}
