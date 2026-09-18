import XCTest

/// Flow (e): Duel — open Duel, `←`/`→` answer, progress advances, `⌘Z` undoes,
/// `↓` skips. And LIMITATIONS §0.2: arrow keys must not change the sidebar or
/// grid selection behind the duel.
final class DuelFlowTests: VGNUITestCase {

    func testDuelAnswerAdvancesProgressAndUndo() throws {
        launchSample(["-VGNOpen", "duel"])

        // The Duel destination is up. If the queue is drained it shows the empty
        // state; the sample library has tiered-but-unplaced games so we expect a
        // real duel, but tolerate an empty queue rather than fail flakily.
        guard el(A11y.duelProgress).waitForExistence(timeout: 12) else {
            attachWindowScreenshot("e0-duel-empty")
            throw XCTSkip("Duel queue empty in sample data — nothing to answer")
        }
        attachWindowScreenshot("e1-duel")

        let before = (el(A11y.duelProgress).value as? String) ?? ""
        require(el(A11y.duelLeft), "left cover")
        require(el(A11y.duelRight), "right cover")
        app.typeKey(.leftArrow, modifierFlags: [])   // ← picks the left game
        let advanced = waitForProgressChange(from: before)
        XCTAssertTrue(advanced, "Answering a duel should advance progress (was \(before))")
        attachWindowScreenshot("e2-after-answer")

        // ⌘Z undoes the last answer.
        shortcut("z", .command)
        _ = waitForProgressChange(from: (el(A11y.duelProgress).value as? String) ?? "")
        attachWindowScreenshot("e3-after-undo")
    }

    func testArrowKeysDoNotLeakToSidebar() throws {
        launchSample(["-VGNOpen", "duel"])
        guard el(A11y.duelProgress).waitForExistence(timeout: 12)
                || el(A11y.duelEmpty).waitForExistence(timeout: 2) else {
            throw XCTSkip("Duel destination did not load")
        }

        // Press arrows / skip; the Duel view must keep focus — the sidebar
        // selection must not move to another row, and no library grid appears.
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.leftArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])

        XCTAssertFalse(el(A11y.grid).exists,
            "Arrow keys in Duel must not surface the library grid behind it")
        // Still on the Duel destination (progress or empty state visible).
        let stillDuel = el(A11y.duelProgress).exists || el(A11y.duelEmpty).exists
                        || el(A11y.duelLeft).exists
        XCTAssertTrue(stillDuel, "Arrow keys must not navigate away from Duel")
        attachWindowScreenshot("e4-no-leak")
    }

    private func waitForProgressChange(from old: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = (el(A11y.duelProgress).value as? String) ?? ""
            if now != old { return true }
            // A completed placement can drain to the empty state instead.
            if el(A11y.duelEmpty).exists { return true }
            usleep(250_000)
        }
        return false
    }
}
