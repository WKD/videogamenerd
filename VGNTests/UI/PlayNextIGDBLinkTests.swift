import AppKit
import SwiftUI
import Testing
@testable import VGN

/// The Play Next "Open on IGDB" card button (owner 2026-09-20): the shared URL helper, the
/// suggestion carrying the IGDB id, and the button routing through an injectable opener so a
/// test can assert the URL without opening a browser.
struct PlayNextIGDBLinkTests {

    // MARK: - Pure URL helper (single scheme, reused from the reconcile sheet)

    @Test func searchURLEncodesTitleAndIsNilWhenBlank() {
        let url = IGDBWebLink.searchURL(name: "NieR: Automata")
        #expect(url?.absoluteString.hasPrefix("https://www.igdb.com/search") == true)
        #expect(url?.absoluteString.contains("type=1") == true)
        #expect(url?.absoluteString.contains("q=") == true)
        #expect(IGDBWebLink.searchURL(name: "   ") == nil)
    }

    @Test func pageURLNeedsAnIGDBID() {
        #expect(IGDBWebLink.pageURL(igdbID: 1234, title: "Hollow Knight")
                == IGDBWebLink.searchURL(name: "Hollow Knight"))
        #expect(IGDBWebLink.pageURL(igdbID: nil, title: "Hollow Knight") == nil)
    }

    // MARK: - Suggestion exposes the URL only when matched

    @Test func matchedSuggestionExposesURLUnmatchedDoesNot() {
        let matched = PlayNextSamples.suggestion(1, "Elden Ring", reasons: [], igdbID: 555)
        let manual = PlayNextSamples.suggestion(2, "My Homebrew", reasons: [], hasMetadata: false)
        #expect(IGDBWebLink.pageURL(igdbID: matched.igdbID, title: matched.title) != nil)
        #expect(IGDBWebLink.pageURL(igdbID: manual.igdbID, title: manual.title) == nil)
    }
}

/// The button really fires the injected opener (and nothing opens a browser).
@MainActor
@Suite(.serialized)
struct PlayNextIGDBClickTests {

    @Test(.timeLimit(.minutes(3)))
    func heroOpenIGDBButtonCallsTheInjectedOpener() async throws {
        final class Box: @unchecked Sendable { var url: URL? }
        let box = Box()
        let suggestion = PlayNextSamples.suggestion(7, "Hollow Knight", reasons: [], igdbID: 999)
        let card = PlayNextHeroCard(
            suggestion: suggestion, sentences: [], bracket: TimeBracket(shelf: .epic),
            loader: NoopCoverLoader(),
            onStart: {}, onNot: {}, onNever: {}, onInspect: {},
            openURL: { box.url = $0 })
        let window = ClickProbeWindow(card.frame(width: 640, height: 340))
        defer { window.close() }
        try await window.settle()
        // Sweep the action band at the bottom of the card. No Menu in the hero action row, so a
        // synthetic click is safe (the other buttons' no-op closures are harmless).
        _ = try await window.sweep(band: 320, stepX: 16, stepY: 16,
                                   observe: { box.url == nil ? 0 : 1 },
                                   until: { box.url != nil })
        #expect(box.url == IGDBWebLink.pageURL(igdbID: 999, title: "Hollow Knight"))
    }
}
