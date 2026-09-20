import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Wave-18 click-probe sweep — RANKING screens (Duel, Triage, Tier Board, The Top).
///
/// Model tests cannot see hit-testing bugs (two shipped: a plain tap shadowing modifier clicks;
/// a horizontal `ScrollView` under the toolbar swallowing clicks). These host the REAL views in
/// an off-screen, toolbar-shaped ``ClickProbeWindow`` and prove, with real synthetic mouse
/// events, that the primary controls receive clicks — asserting the model / backend effect
/// (never `UndoManager.undo()`, which hangs headless). Every ranking view is menu-free
/// (`docs/…`: no `Menu`/pop-up/DatePicker), and each click is pop-up-guarded regardless, so a
/// sweep can never open a menu. No database, no network.
@MainActor
@Suite(.serialized)
struct ClickSweepRankingTests {

    private func host(_ content: some View, size: NSSize = NSSize(width: 900, height: 640)) -> ClickProbeWindow {
        ClickProbeWindow(content.frame(minWidth: size.width, minHeight: size.height).toolbar { Button("x") {} },
                         size: size)
    }

    // MARK: - Duel (the two choice buttons)

    @Test(.timeLimit(.minutes(3)))
    func duelLeftChoiceButtonReceivesClicks() async throws {
        let backend = ScriptedRankingBackend.previewPlacement()
        let model = DuelModel(backend: backend)
        await model.start()
        #expect(model.display != nil, "the fake placement prompt should load")

        let window = host(DuelView(model: model, loader: NoopCoverLoader()))
        defer { window.close() }
        await window.settleShort()
        // Left choice card fills the left half; sweep only the left third so the click lands on
        // it (not the right one) → the model answers and the backend records a winner.
        let hit = await window.sweepBand(yTop: window.contentTop - 40, yBottom: 60,
                                         xMax: window.window.frame.width * 0.34) { !backend.answered.isEmpty }
        #expect(hit, "the Duel left choice button never received a click")
    }

    @Test(.timeLimit(.minutes(3)))
    func duelRightChoiceButtonReceivesClicks() async throws {
        let backend = ScriptedRankingBackend.previewPlacement()
        let model = DuelModel(backend: backend)
        await model.start()

        let window = host(DuelView(model: model, loader: NoopCoverLoader()))
        defer { window.close() }
        await window.settleShort()
        let hit = await window.sweepBand(yTop: window.contentTop - 40, yBottom: 60,
                                         xMin: window.window.frame.width * 0.66) { !backend.answered.isEmpty }
        #expect(hit, "the Duel right choice button never received a click")
    }

    // MARK: - Triage (tier legend + Back = the un-tier / "back" affordance)

    @Test(.timeLimit(.minutes(3)))
    func triageTierLegendAndBackReceiveClicks() async throws {
        let backend = ScriptedRankingBackend.previewTriage()
        let model = TriageModel(backend: backend)
        await model.start()
        #expect(!model.pending.isEmpty, "the fake triage queue should load")

        let window = host(TriageView(model: model, loader: NoopCoverLoader()))
        defer { window.close() }
        await window.settleShort()

        // The tier legend is a row of six plain Buttons pinned to the bottom; a click tiers the
        // current game → the backend records the tier call. (Legend + Skip/Back are the Triage
        // "choice" controls; the tier letters are also keyboard-tested in the model suite.)
        let tiered = await window.sweepBottomBand(height: 120) { !backend.tierCalls.isEmpty }
        #expect(tiered, "the Triage tier legend never received a click")

        // Now that a game is tiered, the "Back" button (top of the card) un-tiers it — a
        // `setTier(…, nil)` call, the "back"/undo-equivalent (UndoManager hangs headless). Sweep
        // the top band until a nil-tier call appears (a stray Skip hit just rotates the queue).
        if model.canGoBack {
            let wentBack = await window.sweepTopBand(height: 120) {
                backend.tierCalls.contains { $0.tierID == nil }
            }
            #expect(wentBack, "the Triage Back button never received a click")
        }
    }

    // MARK: - Tier Board (tile click → single-select; the modifier-shadowing bug's shape)

    @Test(.timeLimit(.minutes(3)))
    func tierBoardTileClickSelects() async throws {
        let backend = ScriptedRankingBackend.previewBoard(placedPerTier: 3, unplacedPerTier: 0)
        let model = TierBoardModel(backend: backend)
        await model.start()
        #expect(!model.rows.isEmpty, "the fake board should load")

        let window = host(TierBoardView(model: model, loader: NoopCoverLoader()))
        defer { window.close() }
        await window.settleShort()

        // Tiles fill the board below a thin header; a plain click must single-select (the ⌘-tap
        // additive path is a separate gesture — the exact shape of the shipped modifier-shadow
        // bug). Sweep the board area; tiles open a context menu only on right-click, never here.
        let selected = await window.sweepTopBand(height: 300) { !model.selection.isEmpty }
        #expect(selected, "clicking a Tier Board tile did not select it (a plain click may be shadowed)")
    }

    // MARK: - The Top (row click → focus/select; empty-state "Start ranking")

    @Test(.timeLimit(.minutes(3)))
    func theTopRowClickSelects() async throws {
        let backend = ScriptedRankingBackend.previewTop(n: 16)
        let model = TheTopModel(backend: backend)
        await model.start()
        #expect(!model.rows.isEmpty, "the fake Top should load rows")

        let window = host(TheTopView(model: model, loader: NoopCoverLoader()))
        defer { window.close() }
        await window.settleShort()

        // Avoid the top ~90 pt: the header holds "Export CSV", which opens a REAL NSSavePanel
        // (modal, blocks the run like a menu). The rows sit below it — a click focuses one.
        let focused = await window.sweepBand(yTop: window.contentTop - 90, yBottom: 60) {
            model.focusedID != nil
        }
        #expect(focused, "clicking a The Top row did not focus/select it")
    }

    @Test(.timeLimit(.minutes(3)))
    func theTopEmptyStateStartRankingButtonFires() async throws {
        var startedRanking = false
        let actions = RankingViewActions(goToDuel: { startedRanking = true })
        // A bare backend yields no rows → the empty state with the "Start ranking" button.
        let model = TheTopModel(backend: ScriptedRankingBackend(), actions: actions)
        await model.start()
        #expect(model.rows.isEmpty)

        // The view re-installs its actions from the environment in `.task`, so inject there.
        let window = host(TheTopView(model: model, loader: NoopCoverLoader())
            .environment(\.rankingActions, actions))
        defer { window.close() }
        await window.settleShort()

        // Sweep the CENTRE of the content only: the "Start ranking" button is centred there,
        // while the top band holds a control that can open a modal, and the edges are noise.
        let w = window.window.frame.width
        let fired = await window.sweepBand(yTop: window.contentTop - 110, yBottom: 40,
                                           stepX: 18, stepY: 12, xMin: w * 0.28, xMax: w * 0.72,
                                           maxClicks: 600) { startedRanking }
        #expect(fired, "The Top empty-state ‘Start ranking’ button never fired")
    }
}
