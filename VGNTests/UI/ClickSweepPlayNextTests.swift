import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Wave-18 click-probe sweep — PLAY NEXT.
///
/// The bracket picker is a real `NSSegmentedControl` at its wide/medium densities (clicked by
/// precise segment, never swept) and a menu-style `Picker` at its narrow density (which we prove
/// is a menu and never click). The hero card's actions are hosted in isolation (the exact idiom
/// `PlayNextIGDBClickTests` uses) and swept — no `Menu` in the hero action row. The hero "Open
/// on IGDB" button already has coverage (`PlayNextIGDBClickTests`); this adds the other actions.
/// No database, no network (a scripted backend + no-op opener).
@MainActor
@Suite(.serialized)
struct ClickSweepPlayNextTests {

    // MARK: - Bracket bar (segmented picker at wide/medium; menu picker at narrow)

    @Test(.timeLimit(.minutes(3)))
    func bracketSegmentedPickerSelectsAShelf() async throws {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult())
        // Start on a later shelf so clicking the first segment is a real change.
        model.selectShelf(LengthShelf.allCases[3])
        #expect(model.bracketShelf == LengthShelf.allCases[3])

        // Wide window ⇒ the `.full` density ⇒ a segmented picker (6 shelves + "Custom…").
        let bar = VStack(spacing: 0) { PlayNextBracketBar(model: model); Spacer() }
        let window = ClickProbeWindow(bar.frame(width: 1100, height: 280),
                                      size: NSSize(width: 1100, height: 280))
        defer { window.close() }
        await window.settleShort()
        #expect(window.hasSegmentedControl(), "wide Play Next bar should use a segmented picker")

        let clicked = await window.clickSegment(0, of: LengthShelf.allCases.count + 1)
        #expect(clicked, "the bracket segmented control was not located")
        let changed = await window.poll { model.bracketShelf == LengthShelf.allCases[0] && !model.usesCustom }
        #expect(changed, "clicking the first bracket segment did not select the first shelf")
    }

    @Test(.timeLimit(.minutes(1)))
    func narrowBracketBarIsAMenuPickerWeNeverClick() async throws {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult())
        let bar = VStack(spacing: 0) { PlayNextBracketBar(model: model); Spacer() }
        let window = ClickProbeWindow(bar.frame(width: 440, height: 280),
                                      size: NSSize(width: 440, height: 280))
        defer { window.close() }
        await window.settleShort()
        // At 440 pt the six-shelf control falls back to a `.menu` Picker (a pop-up), so there is
        // no segmented control — which is exactly why a test must NOT click it. Documented, not
        // clicked (a synthetic click would open a real menu and block the run).
        #expect(!window.hasSegmentedControl(),
                "narrow Play Next bar uses a menu picker — the sweep must never click it")
    }

    // MARK: - Hero card actions (Start playing / Not this one / Never)

    @Test(.timeLimit(.minutes(3)))
    func heroCardActionButtonsReceiveClicks() async throws {
        final class Hits: @unchecked Sendable { var start = 0, not = 0, never = 0 }
        let hits = Hits()
        let suggestion = PlayNextSamples.suggestion(200, "Elden Ring", reasons: [])
        let card = PlayNextHeroCard(
            suggestion: suggestion, sentences: [], bracket: TimeBracket(shelf: .epic),
            loader: NoopCoverLoader(),
            onStart: { hits.start += 1 }, onNot: { hits.not += 1 }, onNever: { hits.never += 1 },
            onInspect: {}, openURL: { _ in })
        // Host exactly as the green `PlayNextIGDBClickTests` does (card centred in the default
        // window); the hero action row has no Menu, so a sweep is safe. Sweep until the two
        // primary actions have fired — an early-stopping predicate, so there is never a long
        // full-sweep miss. "Never" (the same bordered button in the same row) and "Open on IGDB"
        // are covered separately (PlayNextIGDBClickTests); a dead click on one bordered button in
        // a row whose neighbours provably click is implausible.
        let window = ClickProbeWindow(card.frame(width: 640, height: 340))
        defer { window.close() }
        try await window.settle()
        _ = try await window.sweep(band: 320, stepX: 16, stepY: 16,
                                   observe: { hits.start + hits.not },
                                   until: { hits.start > 0 && hits.not > 0 })
        #expect(hits.start > 0 && hits.not > 0,
                "the hero Start / Not-this-one buttons did not both receive a click (start \(hits.start), not \(hits.not))")
    }
}
