import Foundation
import Testing
@testable import VGN

/// The Play Next model (PLAN §7b): bracket/option persistence, latest-wins
/// recompute, re-roll, actions, the small-library threshold, and the second-opinion
/// state machine (cache, cancel, failure, invalidation). Driven against a fake
/// backend + stub provider — `@MainActor`, serialized, hard-timeout.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayNextModelTests {

    // MARK: - Helpers

    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "playnext.test.\(UUID().uuidString)")!
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async {
        let start = ContinuousClock.now
        while !cond() {
            if ContinuousClock.now - start > timeout { break }
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    private func makeModel(
        _ backend: ScriptedPlayNextBackend,
        provider: any SecondOpinionProviding = StubSecondOpinionProvider(),
        defaults: UserDefaults? = nil
    ) -> PlayNextModel {
        PlayNextModel(backend: backend, secondOpinion: provider,
                      defaults: defaults ?? ephemeral(), recomputeDebounce: .milliseconds(1))
    }

    // MARK: - Persistence

    @Test func bracketAndOptionsPersist() {
        let defaults = ephemeral()
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let m1 = makeModel(backend, defaults: defaults)
        m1.selectPreset(.longHaul)
        m1.setCompletionist(true)
        m1.setIncludeAbandoned(true)
        m1.setIncludePlayedWithoutStatus(true)
        m1.useCustom(hoursPerWeek: 10, weeks: 3)
        m1.stop()

        let m2 = makeModel(backend, defaults: defaults)
        #expect(m2.completionist)
        #expect(m2.includeAbandoned)
        #expect(m2.includePlayedWithoutStatus)
        #expect(m2.usesCustom)
        #expect(m2.customHoursPerWeek == 10)
        #expect(m2.customWeeks == 3)
        #expect(m2.bracketPreset == .longHaul)
    }

    // MARK: - Latest-wins recompute

    @Test func recomputeIsLatestWins() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult())
        backend.recommendDelay = .milliseconds(60)
        backend.recommendHandler = { bracket, _ in
            PlayNextResult(hero: nil, bracket: bracket)
        }
        let model = makeModel(backend)
        await model.start()
        model.selectPreset(.evening)
        model.selectPreset(.month)
        await waitUntil { model.result?.bracket.preset == .month }
        #expect(model.result?.bracket.preset == .month)
    }

    // MARK: - Re-roll

    @Test func rerollChangesSeed() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = makeModel(backend)
        await model.start()
        await waitUntil { model.hasLoaded }
        let before = backend.recommendCalls.last?.options.seed
        model.reroll()
        await waitUntil { backend.recommendCalls.last?.options.seed != before }
        #expect(backend.recommendCalls.last?.options.seed != before)
    }

    // MARK: - Actions

    @Test func actionsCallStoreAndRefresh() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        backend.exemplars = PlayNextSamples.exemplars
        let model = makeModel(backend)
        await model.start()
        await waitUntil { model.hasLoaded }
        let hero = model.result!.hero!
        let before = backend.recommendCalls.count

        await model.notThisOne(hero)
        #expect(backend.snoozed == [hero.id])
        #expect(model.toast?.text.contains("Snoozed") == true)
        await waitUntil { backend.recommendCalls.count > before }
        #expect(backend.recommendCalls.count > before)

        await model.never(hero)
        #expect(backend.nevered == [hero.id])
        await model.startPlaying(hero)
        #expect(backend.startedPlaying == [hero.id])
    }

    // MARK: - Small-library threshold

    @Test func smallLibraryThreshold() async {
        let small = PlayNextSamples.model(result: PlayNextSamples.richResult(), ranked: 8)
        await small.start()
        await waitUntil { small.rankedCount == 8 }
        #expect(small.isSmallLibrary)

        let big = PlayNextSamples.model(result: PlayNextSamples.richResult(), ranked: 20)
        await big.start()
        await waitUntil { big.rankedCount == 20 }
        #expect(!big.isSmallLibrary)
    }

    // MARK: - Second opinion: result + agreement

    @Test func secondOpinionResultAndAgreement() async {
        let stub = StubSecondOpinionProvider(opinion: SecondOpinion.picks([200, 201]))
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub)
        await model.start()
        await waitUntil { model.hasLoaded }
        model.askClaude()
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }
        #expect(model.secondOpinionAgreesOnHero)      // hero 200 == Claude's #1
        #expect(model.hasShownAskDisclosure)          // disclosure marked shown
    }

    // MARK: - Second opinion: session cache avoids a second call

    @Test func secondOpinionCacheHitAvoidsSecondCall() async {
        let stub = StubSecondOpinionProvider(opinion: SecondOpinion.picks([201, 200]))
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub)
        await model.start()
        await waitUntil { model.hasLoaded }
        model.askClaude()
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }
        #expect(stub.callCount == 1)
        model.dismissSecondOpinion()
        model.askClaude()                              // same (shortlist, bracket) → cache
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }
        #expect(stub.callCount == 1)
    }

    // MARK: - Second opinion: cancellation

    @Test func secondOpinionCancellation() async {
        let stub = StubSecondOpinionProvider()
        stub.echoEngineOrder = true
        stub.delay = 5
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub)
        await model.start()
        await waitUntil { model.hasLoaded }
        model.askClaude()
        await waitUntil { model.secondOpinionState == .asking }
        model.cancelSecondOpinion()
        #expect(model.secondOpinionState == .idle)
    }

    // MARK: - Second opinion: failure → friendly state

    @Test func secondOpinionFailure() async {
        let stub = StubSecondOpinionProvider(error: .unavailable("Claude Code is not installed."))
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub)
        await model.start()
        await waitUntil { model.hasLoaded }
        model.askClaude()
        await waitUntil { if case .failed = model.secondOpinionState { return true }; return false }
        guard case let .failed(error) = model.secondOpinionState else { return #expect(Bool(false)) }
        #expect(error.suggestsSettings)
        #expect(!error.message.isEmpty)
    }

    // MARK: - Second opinion: invalidated when the shortlist changes

    @Test func secondOpinionInvalidatedOnShortlistChange() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        backend.exemplars = PlayNextSamples.exemplars
        let stub = StubSecondOpinionProvider(opinion: SecondOpinion.picks([200]))
        let model = makeModel(backend, provider: stub)
        await model.start()
        await waitUntil { model.hasLoaded }
        model.askClaude()
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }

        // A recompute yields a different shortlist → the opinion is invalidated.
        backend.result = PlayNextResult(
            hero: PlayNextSamples.suggestion(999, "Different", reasons: []),
            bracket: TimeBracket(preset: .longHaul))
        model.reroll()
        await waitUntil { model.result?.hero?.id == 999 }
        #expect(model.secondOpinionState == .idle)
    }
}
