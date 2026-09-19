import Foundation
import Testing
@testable import VGN

/// Undo for Play Next "Start playing" at the model level (PLAN §7b). Driven against
/// the scripted backend + a real `UndoManager`; the inverse is invoked directly
/// (`UndoManager.undo()` hangs headless) and no wall-clock time is asserted.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayNextUndoTests {

    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "playnext.undo.\(UUID().uuidString)")!
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async {
        let start = ContinuousClock.now
        while !cond() {
            if ContinuousClock.now - start > timeout { break }
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    private func loadedModel(_ backend: ScriptedPlayNextBackend) async -> PlayNextModel {
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: ephemeral(), recomputeDebounce: .milliseconds(1))
        await model.start()
        await waitUntil { model.hasLoaded }
        return model
    }

    @Test("Start playing offers an undoable toast and registers a window undo")
    func startRegistersUndo() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = await loadedModel(backend)
        let undo = UndoManager()
        model.undoManager = undo
        let hero = model.result!.hero!

        await model.startPlaying(hero)
        #expect(backend.startedPlaying == [hero.id])
        #expect(model.pendingStartUndo?.gameID == hero.id)
        #expect(model.toast?.undoable == true)
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Start Playing")
    }

    @Test("Undo calls the backend inverse and is single-shot")
    func undoCallsBackendOnce() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = await loadedModel(backend)
        model.undoManager = UndoManager()
        let hero = model.result!.hero!

        await model.startPlaying(hero)
        let token = model.pendingStartUndo!
        await model.undoLastStartPlaying()
        #expect(backend.undone == [token])
        #expect(model.pendingStartUndo == nil)

        // A second undo (e.g. ⌘Z after the toast button) is ignored.
        await model.performUndoStartPlaying(token)
        #expect(backend.undone.count == 1)
    }

    @Test("A refused undo surfaces the reason and does not clear via success path")
    func refusedUndoSurfacesReason() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        backend.undoOutcome = .refusedRanked
        let model = await loadedModel(backend)
        let hero = model.result!.hero!

        await model.startPlaying(hero)
        await model.undoLastStartPlaying()
        #expect(backend.undone.count == 1)
        #expect(model.toast?.text.contains("ranked it") == true)
    }

    @Test("A newer action supersedes the pending undo, and the stale undo is inert")
    func newerActionClearsUndo() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = await loadedModel(backend)
        model.undoManager = UndoManager()
        let hero = model.result!.hero!

        await model.startPlaying(hero)
        let stale = model.pendingStartUndo!
        await model.notThisOne(hero)               // a different action
        #expect(model.pendingStartUndo == nil)
        // Invoking the now-stale start-playing undo (e.g. via ⌘Z) does nothing.
        await model.performUndoStartPlaying(stale)
        #expect(backend.undone.isEmpty)
    }
}
