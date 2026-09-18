import XCTest

/// Flow (l): Settings — `⌘,` opens the Settings window, the three tabs exist, and
/// the Photo Scan tab shows the detected `claude` line and the Check button.
/// Check is not pressed: opening the tab already runs the same probe, which only
/// executes `command -v claude` + `claude --version` (no `claude -p`, no usage).
final class SettingsTests: VGNUITestCase {

    func testSettingsTabsAndPhotoScanTab() {
        launchSample()
        require(el(A11y.grid), "grid")

        shortcut(",", .command)
        for tab in ["Accounts", "Photo Scan", "General"] {
            require(tabButton(tab), "\(tab) settings tab")
        }

        tabButton("Photo Scan").click()
        require(el(A11y.settingsCheck), "Check button")
        require(el(A11y.settingsClaudePath), "detected claude line")
        attachSettingsScreenshot("l1-settings-photoscan")

        tabButton("General").click()
        require(el(A11y.settingsTabGeneral), "General tab content")
        attachSettingsScreenshot("l2-settings-general")

        app.typeKey("w", modifierFlags: .command)
    }

    /// A Settings `TabView` tab: a toolbar button on macOS 15, a radio button / tab
    /// on other releases — match on the label, whatever the element type.
    private func tabButton(_ label: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "label == %@ AND (elementType == %d OR elementType == %d OR elementType == %d)",
            label,
            XCUIElement.ElementType.button.rawValue,
            XCUIElement.ElementType.radioButton.rawValue,
            XCUIElement.ElementType.tab.rawValue)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Window-only screenshot of the Settings window (the one holding the tabs),
    /// never the screen.
    private func attachSettingsScreenshot(_ name: String) {
        let settings = app.windows.containing(.button, identifier: A11y.settingsCheck).firstMatch
        let target = settings.exists ? settings : app.windows.firstMatch
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
