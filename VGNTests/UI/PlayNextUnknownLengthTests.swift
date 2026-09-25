import Foundation
import Testing
@testable import VGN

/// Wave 23 — Play Next must not say "Nothing to play here yet" when every candidate only
/// lacks a length estimate. Three situations: none / only unknown-length / normal.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayNextUnknownLengthTests {

    private func unknownOnlyResult() -> PlayNextResult {
        let games = [
            PlayNextSamples.suggestion(301, "Untimed One", estimate: nil,
                                       reasons: [.crowdRated(rating: 88, count: 900)]),
            PlayNextSamples.suggestion(302, "Untimed Two", estimate: nil, reasons: []),
        ]
        var exclusions = RecommendationExclusions()
        exclusions.unknownLength = 2
        return PlayNextResult(unknownLength: games, exclusions: exclusions,
                              bracket: TimeBracket(shelf: .weekend))
    }

    private func settledModel(_ result: PlayNextResult) async -> PlayNextModel {
        let backend = ScriptedPlayNextBackend(result: result)
        let model = PlayNextModel(
            backend: backend, secondOpinion: StubSecondOpinionProvider(),
            defaults: UserDefaults(suiteName: "playnext.unknown.\(UUID().uuidString)")!,
            recomputeDebounce: .milliseconds(1))
        await model.start()
        let start = ContinuousClock.now
        while model.result == nil, ContinuousClock.now - start < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(4))
        }
        return model
    }

    // MARK: - Result predicates

    @Test func noCandidatesIsEmpty() {
        let result = PlayNextSamples.emptyResult()
        #expect(result.isEmpty)
        #expect(!result.hasOnlyUnknownLength)
    }

    @Test func unknownLengthOnlyIsNotEmpty() {
        let result = unknownOnlyResult()
        #expect(!result.isEmpty)
        #expect(result.hasOnlyUnknownLength)
        #expect(!result.hasPicks)
    }

    @Test func normalResultHasPicks() {
        let result = PlayNextSamples.richResult()
        #expect(!result.isEmpty)
        #expect(result.hasPicks)
        #expect(!result.hasOnlyUnknownLength)
    }

    // MARK: - Model state

    @Test func modelShowsEmptyOnlyWhenTrulyNothing() async {
        let model = await settledModel(PlayNextSamples.emptyResult())
        #expect(model.contentState == .empty)
        model.stop()
    }

    @Test func modelShowsUnknownLaneWhenOnlyUnknownLength() async {
        let model = await settledModel(unknownOnlyResult())
        #expect(model.contentState == .onlyUnknownLength)
        #expect(model.result?.unknownLength.map(\.id) == [301, 302])
        model.stop()
    }

    @Test func modelShowsPicksNormally() async {
        let model = await settledModel(PlayNextSamples.richResult())
        #expect(model.contentState == .picks)
        model.stop()
    }

    @Test func noRankingsWinsAndLoadingBeforeResult() {
        #expect(PlayNextModel.contentState(rankedCount: 0, result: unknownOnlyResult()) == .noRankings)
        #expect(PlayNextModel.contentState(rankedCount: 5, result: nil) == .loading)
    }

    // MARK: - Copy

    @Test func unknownCardsLeadWithTheNoEstimateReason() {
        let sentences = PlayNextEmptyCopy.unknownLengthSentences(["a", "b", "c"])
        #expect(sentences.first == PlayNextEmptyCopy.noEstimateReason)
        #expect(sentences.count == PlayNextReasonFormatter.maxReasons)
        #expect(PlayNextEmptyCopy.unknownLengthSentences([]) == [PlayNextEmptyCopy.noEstimateReason])
    }

    @Test func noLengthsCopyIsConcrete() {
        let copy = PlayNextEmptyCopy.noLengthsYet(count: 1)
        #expect(copy.title == "None of your unfinished games has a length yet")
        #expect(copy.message.contains("this game has no time estimate"))
        #expect(PlayNextEmptyCopy.noLengthsYet(count: 3).message.contains("these 3 games have no time estimate"))
        #expect(!copy.message.contains("!"))
    }
}
