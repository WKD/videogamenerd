import XCTest

/// Flow (h): inspector edits — played toggle, status, playtime field accepts
/// `45h` and shows it formatted, invalid input shows validation.
final class InspectorEditTests: VGNUITestCase {

    private func openInspector(on title: String) {
        launchSample()
        require(el(A11y.grid), "grid")
        require(gridCell(titled: title), "\(title) cell").click()
        shortcut("i", .command)   // ⌘I toggles the inspector open
        require(el(A11y.inspector), "inspector")
    }

    func testPlayedToggle() {
        openInspector(on: "Disco Elysium")   // seeds unplayed
        let toggle = require(el(A11y.inspectorPlayedToggle), "played toggle")
        let before = (toggle.value as? String) ?? ""
        toggle.click()
        // The grid cell's state should reflect the flip.
        let flipped = waitUntil { ((gridCell(titled: "Disco Elysium").value as? String) ?? "").contains("Played") }
        XCTAssertTrue(flipped, "Toggling played in the inspector should mark the game played (toggle was \(before))")
        attachWindowScreenshot("h1-played-toggle")
    }

    func testPlaytimeAcceptsFormattedInput() {
        openInspector(on: "Elden Ring")   // seeds played
        let field = require(el(A11y.inspectorPlaytimeField), "playtime field")
        field.click()
        field.typeText("45h")
        app.typeKey(.return, modifierFlags: [])
        let shows45 = waitUntil { ((el(A11y.inspectorPlaytimeField).value as? String) ?? "").contains("45") }
        XCTAssertTrue(shows45, "Playtime field should accept and format '45h'")
        attachWindowScreenshot("h2-playtime-45h")
    }

    func testPlaytimeRejectsInvalidInput() {
        openInspector(on: "Elden Ring")
        let field = require(el(A11y.inspectorPlaytimeField), "playtime field")
        field.click()
        // Clear then enter garbage. It must not be accepted as a playtime value.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("not-a-time")
        app.typeKey(.return, modifierFlags: [])
        let value = (el(A11y.inspectorPlaytimeField).value as? String) ?? ""
        XCTAssertFalse(value.contains("not-a-time"),
            "Invalid playtime input must not be stored verbatim (was \(value))")
        attachWindowScreenshot("h3-playtime-invalid")
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(200_000)
        }
        return predicate()
    }
}
