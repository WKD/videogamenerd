import XCTest

/// Flow (k): Scan — `⇧⌘O` opens the scan sheet in its input state with the usage
/// notice; it can be closed again. **Never starts a scan** (a scan spawns the
/// `claude` CLI and spends the owner's subscription usage).
final class ScanSheetTests: VGNUITestCase {

    func testScanSheetOpensShowsUsageNoticeAndCloses() {
        launchSample()
        require(el(A11y.grid), "grid")

        shortcut("o", [.shift, .command])
        require(el(A11y.scanUsageNotice), "scan usage notice")
        // Input state: nothing queued, so the default "Scan 0 Photos" button is
        // disabled — assert that rather than ever pressing it.
        let scanButtons = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Scan "))
        if scanButtons.count > 0 {
            XCTAssertFalse(scanButtons.firstMatch.isEnabled,
                "With no photos queued the Scan button must be disabled")
        }
        attachWindowScreenshot("k1-scan-sheet")

        // Close it: the Cancel button, else esc (both must dismiss the sheet).
        let close = el(A11y.scanClose)
        if close.exists { close.click() } else { app.typeKey(.escape, modifierFlags: []) }

        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, el(A11y.scanUsageNotice).exists { usleep(200_000) }
        XCTAssertFalse(el(A11y.scanUsageNotice).exists,
            "The scan sheet must be dismissable from its input state")
        attachWindowScreenshot("k2-scan-closed")
    }
}
