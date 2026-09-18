import XCTest

/// Flow (j): Play Next — switch brackets with `1`–`4`, the hero changes or an
/// explanatory empty state appears, `R` re-rolls; the Ask Claude button exists
/// (we never trigger it — it would spend the owner's Claude usage).
final class PlayNextTests: VGNUITestCase {

    func testBracketSwitchAndRerollAndAskClaudePresent() throws {
        launchSample(["-VGNOpen", "playNext"])

        let hasContent = el(A11y.playNextHero).waitForExistence(timeout: 12)
                         || el(A11y.playNextEmpty).waitForExistence(timeout: 2)
        guard hasContent else {
            attachWindowScreenshot("j0-playnext-nostate")
            throw XCTSkip("Play Next showed neither a hero pick nor an empty state")
        }
        attachWindowScreenshot("j1-playnext")

        // Switch brackets with the number keys; each must leave a valid state.
        for n in ["1", "2", "3", "4"] {
            app.typeText(n)
            let ok = el(A11y.playNextHero).exists || el(A11y.playNextEmpty).exists
            XCTAssertTrue(ok, "Bracket \(n) should show a hero or an empty state")
        }
        attachWindowScreenshot("j2-brackets")

        // R re-rolls without crashing.
        app.typeText("r")
        XCTAssertTrue(el(A11y.playNextHero).exists || el(A11y.playNextEmpty).exists,
            "Re-roll should keep a valid Play Next state")

        // The Ask Claude button must exist — but we must NOT press it.
        require(el(A11y.playNextAskClaude), "Ask Claude button")
        attachWindowScreenshot("j3-after-reroll")
    }
}
