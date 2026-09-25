import XCTest

/// Flow (d): Quick Add floating panel (PLAN §6.1, LIMITATIONS §0.1 — the NSPanel
/// owning the keyboard on macOS 15). ⌘N opens it focused; typing shows local
/// results + the offline hint (sample mode is offline); ⌘O/⌘P/⌘D change the
/// visible flag/format state; "Create … manually" adds and the panel stays open
/// with the field cleared; esc closes; the new game appears in the grid.
final class QuickAddFlowTests: VGNUITestCase {

    func testQuickAddOpensFocusedAndShowsOfflineHint() {
        launchSample()
        require(el(A11y.grid), "grid")

        shortcut("n", .command)
        require(el(A11y.quickAddField), "quick add field")
        // Sample mode has no IGDB credentials → the offline hint must be shown.
        require(el(A11y.quickAddOfflineHint), "offline hint")

        // The field is focused: typing lands in it (proves panel key ownership).
        app.typeText("Testquest Alpha")
        let field = el(A11y.quickAddField)
        XCTAssertEqual((field.value as? String) ?? "", "Testquest Alpha",
            "Typing after ⌘N must land in the focused Quick Add field")
        // A novel title offers the manual-create row.
        require(el(A11y.quickAddManualRow), "Create … manually row")
        attachWindowScreenshot("d1-quickadd-typed")
    }

    func testFlagShortcutsChangeVisibleState() {
        launchSample()
        require(el(A11y.grid), "grid")
        shortcut("n", .command)
        require(el(A11y.quickAddField), "quick add field")
        app.typeText("Testquest Beta")

        // ⌘O toggles owned; reading the owned chip's value must change.
        let ownedBefore = (el(A11y.quickAddOwnedState).value as? String) ?? ""
        shortcut("o", .command)
        let ownedAfter = waitForChange(of: A11y.quickAddOwnedState, from: ownedBefore)
        XCTAssertNotEqual(ownedBefore, ownedAfter, "⌘O should flip the owned chip")

        // ⌘P toggles played.
        let playedBefore = (el(A11y.quickAddPlayedState).value as? String) ?? ""
        shortcut("p", .command)
        let playedAfter = waitForChange(of: A11y.quickAddPlayedState, from: playedBefore)
        XCTAssertNotEqual(playedBefore, playedAfter, "⌘P should flip the played chip")

        // ⌘D cycles the owned format (physical → digital → ROM); only shown while owned.
        if !((el(A11y.quickAddOwnedState).value as? String) ?? "").hasPrefix("Owned") {
            shortcut("o", .command)
            _ = waitForChange(of: A11y.quickAddOwnedState, from: ownedAfter)
        }
        // The format is a 3-segment control since wave 17: the selected segment carries
        // the `.isSelected` trait (the `.contain` group itself exposes no value).
        require(el(A11y.quickAddFormatState), "format picker")
        let formatBefore = selectedFormat()
        XCTAssertNotNil(formatBefore, "One format segment should be selected while owned")
        shortcut("d", .command)
        let formatAfter = waitForSelectedFormat(differentFrom: formatBefore)
        XCTAssertNotEqual(formatBefore, formatAfter, "⌘D should cycle the format")
        attachWindowScreenshot("d2-flags")

        // Tab cycles the platform and ↑/↓ move the selection — neither may steal
        // focus from the text field (LIMITATIONS §0.1): typing must still land in it.
        app.typeKey(.tab, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeText("!")
        XCTAssertEqual((el(A11y.quickAddField).value as? String) ?? "", "Testquest Beta!",
            "Tab / arrows must not move focus out of the Quick Add field")

        // The flags are sticky (persisted preferences): put them back as found.
        shortcut("d", .command); shortcut("d", .command)          // 3-cycle → origin
        if ((el(A11y.quickAddOwnedState).value as? String) ?? "") != ownedBefore { shortcut("o", .command) }
        if ((el(A11y.quickAddPlayedState).value as? String) ?? "") != playedBefore { shortcut("p", .command) }
    }

    func testCreateManuallyStaysOpenClearedThenEscCloses() {
        launchSample()
        require(el(A11y.grid), "grid")
        let title = "Testquest Manual Add"

        shortcut("n", .command)
        require(el(A11y.quickAddField), "quick add field")
        app.typeText(title)

        // A novel title has no results, so ↩ commits the "Create … manually" row:
        // it adds and keeps the palette open (PLAN §6.1).
        require(el(A11y.quickAddManualRow), "manual row")
        app.typeKey(.return, modifierFlags: [])

        // The palette stays open with the field cleared (and focused for the next).
        let field = require(el(A11y.quickAddField), "field still open after add")
        let cleared = waitForFieldEmpty(A11y.quickAddField)
        XCTAssertTrue(cleared, "After a manual add the field should clear and stay open")
        // …and still focused: the next title can be typed straight away.
        app.typeText("zz")
        XCTAssertEqual((el(A11y.quickAddField).value as? String) ?? "", "zz",
            "After an add the field must keep keyboard focus")
        app.typeKey(.escape, modifierFlags: [])   // esc #1 clears the query
        XCTAssertTrue(waitForFieldEmpty(A11y.quickAddField), "esc should first clear the query")
        attachWindowScreenshot("d3-after-manual-add")

        // esc closes the (now empty) palette.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForGone(field), "esc should close the empty palette")

        // The new game shows up in the grid.
        require(gridCell(titled: title), "new game in grid")
        attachWindowScreenshot("d4-new-game-in-grid")
    }

    // MARK: helpers

    /// The raw value of the selected Quick Add format segment (`quickadd.format.<raw>`).
    private func selectedFormat() -> String? {
        ["physical", "digital", "rom"].first { el("quickadd.format.\($0)").isSelected }
    }

    private func waitForSelectedFormat(differentFrom old: String?,
                                       timeout: TimeInterval = 3) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = selectedFormat()
            if now != old { return now }
            usleep(200_000)
        }
        return selectedFormat()
    }

    private func waitForChange(of id: String, from old: String,
                               timeout: TimeInterval = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = (el(id).value as? String) ?? ""
            if now != old { return now }
            usleep(200_000)
        }
        return (el(id).value as? String) ?? ""
    }

    private func waitForFieldEmpty(_ id: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ((el(id).value as? String) ?? "x").isEmpty { return true }
            usleep(200_000)
        }
        return ((el(id).value as? String) ?? "x").isEmpty
    }

    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(200_000)
        }
        return !element.exists
    }
}
