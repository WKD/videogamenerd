import Foundation
import Testing
@testable import VGN

/// The Play Next model side of "Holds up today?" (PLAN §7b): "Include too archaic" is off by
/// default, remembered, and reaches the engine options; the backtest cutoff is remembered and
/// passed to the backend. Fake backend, no database.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HoldsUpPlayNextModelTests {

    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "holdsup.playnext.\(UUID().uuidString)")!
    }

    private func makeModel(_ backend: ScriptedPlayNextBackend, defaults: UserDefaults) -> PlayNextModel {
        PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                      defaults: defaults, recomputeDebounce: .milliseconds(1))
    }

    @Test func includeArchaicDefaultsOffIsRememberedAndPassedOn() {
        let defaults = ephemeral()
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let m1 = makeModel(backend, defaults: defaults)
        #expect(m1.includeArchaic == false)
        #expect(m1.options.includeArchaic == false)
        m1.setIncludeArchaic(true)
        #expect(m1.options.includeArchaic)
        m1.stop()
        let m2 = makeModel(backend, defaults: defaults)
        #expect(m2.includeArchaic)
        #expect(m2.options.includeArchaic)
        m2.stop()
    }

    @Test func backtestCutoffIsRememberedAndSentToTheBackend() async {
        let defaults = ephemeral()
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let m1 = makeModel(backend, defaults: defaults)
        #expect(m1.backtestCutoffYear == nil)
        await m1.setBacktestCutoffYear(1995)
        #expect(backend.backtestCutoffs.last == 1995)
        #expect(m1.backtest?.cutoff?.year == 1995)
        #expect(m1.backtest?.driftLine.contains("without pre-1995 games") == true)
        m1.stop()

        let m2 = makeModel(backend, defaults: defaults)
        #expect(m2.backtestCutoffYear == 1995)
        await m2.setBacktestCutoffYear(nil)
        #expect(backend.backtestCutoffs.last == .some(nil))
        #expect(m2.backtest?.cutoff == nil)
        m2.stop()
        #expect(makeModel(backend, defaults: defaults).backtestCutoffYear == nil)
    }
}
