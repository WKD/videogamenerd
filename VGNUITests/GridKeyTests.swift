import XCTest

/// Flow (c): grid keys — select a game, `⇧A` sets tier A, `⇧P` toggles played,
/// multi-select + tier, `⌘Z` undoes. (Since wave 7 the grid's action keys are
/// SHIFTED — plain letters type-to-select; see `GridKeyRouter`.)
final class GridKeyTests: VGNUITestCase {

    func testTierKeySetsTierThenUndo() {
        launchSample()
        require(el(A11y.grid), "grid")

        // Broken Sword seeds as played + unranked. (Only PLAYED games take a tier —
        // on an unplayed one the key is skipped with a banner, PLAN §4 inv. 2.)
        let game = require(gridCell(titled: "Broken Sword"), "Broken Sword cell")
        game.click()
        XCTAssertFalse(((game.value as? String) ?? "").contains("Tier"),
            "Broken Sword should start unranked")

        app.typeKey("a", modifierFlags: .shift)   // ⇧A over the focused grid → tier A
        expectValue(of: "Broken Sword", contains: "Tier A")
        attachWindowScreenshot("c1-tier-A")

        // ⌘Z undoes the tier change.
        shortcut("z", .command)
        expectValue(of: "Broken Sword", notContains: "Tier A")
        attachWindowScreenshot("c2-undo")
    }

    func testMarkPlayedKey() {
        launchSample()
        require(el(A11y.grid), "grid")

        let disco = require(gridCell(titled: "Disco Elysium"), "Disco Elysium cell")
        disco.click()
        XCTAssertFalse(((disco.value as? String) ?? "").contains("Played"),
            "Disco Elysium should start unplayed")

        app.typeKey("p", modifierFlags: .shift)   // ⇧P toggles played
        expectValue(of: "Disco Elysium", contains: "Played")
        attachWindowScreenshot("c3-mark-played")
    }

    func testMultiSelectTier() {
        launchSample()
        require(el(A11y.grid), "grid")

        let game = require(gridCell(titled: "Broken Sword"), "Broken Sword cell")
        game.click()
        // Extend the selection into the next cell, then tier the set.
        app.typeKey(.rightArrow, modifierFlags: .shift)
        app.typeKey("c", modifierFlags: .shift)   // ⇧C → tier C for the set
        expectValue(of: "Broken Sword", contains: "Tier C")
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
