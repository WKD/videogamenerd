import XCTest

/// Flow (b): search keyboard flow — ⌘F focuses the field, typing filters, ↓ moves
/// into the grid, ↩ opens the inspector, esc clears then unfocuses. And the key
/// leakage guard: typing S/A/B in the search field must NOT re-tier anything.
final class SearchFlowTests: VGNUITestCase {

    func testSearchFocusFilterAndClear() {
        launchSample()
        require(el(A11y.grid), "grid")

        // ⌘F focuses the toolbar search field.
        shortcut("f", .command)
        let field = require(el(A11y.toolbarSearch), "search field")

        // Typing filters the grid to matching titles.
        app.typeText("shadow")
        let filtered = elements(withPrefix: A11y.gridCellPrefix)
        XCTAssertTrue(filtered.count >= 1 && filtered.count <= 3,
            "Expected 'shadow' to narrow the grid, got \(filtered.count) cells")
        attachWindowScreenshot("b1-search-filtered")

        // esc clears the query (stays focused); a second esc unfocuses.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual((field.value as? String) ?? "", "",
            "esc should clear the search text")
        app.typeKey(.escape, modifierFlags: [])
        attachWindowScreenshot("b2-search-cleared")
    }

    func testDownArrowIntoGridThenReturnOpensInspector() {
        launchSample()
        require(el(A11y.grid), "grid")

        shortcut("f", .command)
        require(el(A11y.toolbarSearch), "search field")
        app.typeText("elden")

        // ↓ moves focus into the grid (selecting the first result); ↩ opens it.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        require(el(A11y.inspector), "inspector after ↩ from search")
        attachWindowScreenshot("b3-return-opens-inspector")
    }

    /// Key leakage guard (LIMITATIONS §0.2 / the S/A/B-vs-tier collision, PLAN §8):
    /// with a game selected, focusing the search and typing tier letters must not
    /// re-tier the selection.
    func testTypingTierLettersInSearchDoesNotRetier() {
        launchSample()
        require(el(A11y.grid), "grid")

        // Bloodborne is seeded in tier S. Select it and record its state value.
        let bloodborne = require(gridCell(titled: "Bloodborne"), "Bloodborne cell")
        bloodborne.click()
        let before = (bloodborne.value as? String) ?? ""
        XCTAssertTrue(before.contains("Tier S"),
            "Sample Bloodborne should start in tier S, was \(before)")

        // Focus search and type the tier letters. They must go to the text field.
        shortcut("f", .command)
        require(el(A11y.toolbarSearch), "search field")
        app.typeText("sab")

        // Clear + unfocus, then re-read Bloodborne's tier: it must be unchanged.
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        let after = (gridCell(titled: "Bloodborne").value as? String) ?? ""
        XCTAssertTrue(after.contains("Tier S"),
            "Typing S/A/B in the search field must not re-tier Bloodborne (was \(after))")
        attachWindowScreenshot("b4-no-retier")
    }
}
