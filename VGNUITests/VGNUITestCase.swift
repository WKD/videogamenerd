import XCTest

/// Shared base for VGN's on-demand UI smoke suite (hardening pass, PLAN §8,
/// `docs/EXECUTION.md` "Hardening pass"). XCUITest drives the *real* app through
/// the accessibility layer; it is **never** part of the everyday `VGN` scheme's
/// Test action (see `docs/uitests.md`). Every flow launches an isolated app with
/// `-VGNSampleData YES` (in-memory sample library, no network, no enrichment) so
/// the owner's real library is never touched.
///
/// Screenshots are **window-only** (`app.windows.firstMatch`), never
/// `XCUIScreen.main` — the owner's other windows must never be captured.
///
/// The whole case is `@MainActor`: XCUIApplication/XCUIElement are main-actor
/// isolated in the macOS 26 SDK, and driving them from a nonisolated test method
/// warns under Swift 6 strict concurrency. Subclasses inherit this isolation.
@MainActor
class VGNUITestCase: XCTestCase {

    /// The launched application under test. Set up per test in ``launch``.
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        // A failed assertion should stop the flow rather than hammer the
        // keyboard/mouse further while it is hijacked from the owner.
        continueAfterFailure = false
    }

    // No `tearDown` app-termination: `XCUIApplication.launch()` already terminates
    // any prior instance of the app, so each test starts clean, and the runner
    // terminates the last one when the test process exits. (Touching the
    // main-actor `app` from the nonisolated `tearDown` override would trip Swift 6
    // strict concurrency.)

    /// Launch a fresh sample-data app. `extraArguments` adds DEBUG launch hooks
    /// (e.g. `["-VGNOpen", "duel"]`). Animations are disabled so focus/label
    /// assertions don't race transitions.
    @discardableResult
    func launchSample(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-VGNSampleData", "YES",
            "-VGNDisableAnimations", "YES",
            "-AppleShowScrollBars", "Always",
        ] + extraArguments
        app.launch()
        self.app = app
        return app
    }

    /// The main window. All screenshots must be taken from this, never the screen.
    var window: XCUIElement {
        app.windows.firstMatch
    }

    /// Attach a window-only screenshot (never the full screen) to the report.
    func attachWindowScreenshot(_ name: String) {
        guard let app else { return }
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Common element helpers

    /// The first element of any type carrying `identifier`. Type-agnostic because
    /// SwiftUI maps a `.accessibilityIdentifier` onto different XCUIElement types
    /// depending on the view (button, cell, static text, group…).
    ///
    /// `.firstMatch` is essential: without it, a `descendants(matching: .any)`
    /// subscript makes XCUITest evaluate the *entire* accessibility tree to prove
    /// uniqueness, which on this SwiftUI app times out ("Failed to get matching
    /// snapshots: Timed out while evaluating UI query"). `.firstMatch` short-circuits.
    func el(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Every element whose identifier begins with `prefix` (e.g. all grid cells).
    func elements(withPrefix prefix: String) -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
        return app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
    }

    /// Wait for an element to exist, failing the test with a message otherwise.
    @discardableResult
    func require(_ element: XCUIElement, _ label: String,
                 timeout: TimeInterval = 12,
                 file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "Expected \(label) to exist", file: file, line: line)
        return element
    }

    /// Type a keyboard shortcut against the app (menu / global shortcuts).
    func shortcut(_ key: String, _ flags: XCUIElement.KeyModifierFlags) {
        app.typeKey(key, modifierFlags: flags)
    }

    /// The grid cell whose combined accessibility label contains `title`. Its
    /// `.value` carries the tier / owned / played state (see `GameCell`).
    func gridCell(titled title: String) -> XCUIElement {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            A11y.gridCellPrefix, title)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }
}
