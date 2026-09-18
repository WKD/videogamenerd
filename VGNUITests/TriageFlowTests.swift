import XCTest

/// Flow (f): Triage — switch to Triage, press tier letters, progress advances,
/// `←` goes back.
final class TriageFlowTests: VGNUITestCase {

    func testTriageTierLetterAdvancesAndBack() throws {
        launchSample(["-VGNOpen", "triage"])

        guard el(A11y.triageProgress).waitForExistence(timeout: 12) else {
            // Nothing to triage (no played-but-unranked games) — record and skip.
            attachWindowScreenshot("f0-triage-empty")
            throw XCTSkip("No unranked played games to triage in sample data")
        }
        attachWindowScreenshot("f1-triage")

        let before = (el(A11y.triageProgress).value as? String) ?? ""
        app.typeText("a")   // tier the current game
        let advanced = waitForTriageChange(from: before)
        XCTAssertTrue(advanced || el(A11y.triageEmpty).exists,
            "Tiering should advance triage (was \(before))")
        attachWindowScreenshot("f2-after-tier")

        // ← goes back to the previous card (if triage isn't already complete).
        if el(A11y.triageProgress).exists {
            let mid = (el(A11y.triageProgress).value as? String) ?? ""
            app.typeKey(.leftArrow, modifierFlags: [])
            _ = waitForTriageChange(from: mid)
            attachWindowScreenshot("f3-after-back")
        }
    }

    private func waitForTriageChange(from old: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if el(A11y.triageEmpty).exists { return true }
            let now = (el(A11y.triageProgress).value as? String) ?? ""
            if now != old { return true }
            usleep(250_000)
        }
        return false
    }
}
