#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Play Next (PLAN §7b): hero + alternatives, small-library banner, empty states,
/// and the "Ask Claude" second-opinion column in each of its states.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayNextSnapshotTests {
    private let group = "05 Play Next"
    private let wide = SnapSize(width: 1120, height: 780)
    private let tall = SnapSize(width: 940, height: 780)

    /// Build a `PlayNextBody` over a started model; optionally drive Ask Claude.
    private func body(_ model: PlayNextModel) -> some View {
        PlayNextBody(model: model, loader: NoopCoverLoader(), inspect: { _ in })
    }

    @Test func heroAndAlternatives() async {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult())
        await model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "playnext-hero", size: tall) { body(model) }
    }

    @Test func heroCompact() async {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult())
        await model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "playnext-hero-compact", size: .compact) { body(model) }
    }

    @Test func smallLibrary() async {
        let model = PlayNextSamples.model(
            result: PlayNextSamples.richResult(),
            backtest: TasteBacktestResult(spearman: nil, sampleCount: 9, verdict: .notEnoughData),
            ranked: 9)
        await model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "playnext-small-library", size: tall) { body(model) }
    }

    @Test func nothingFits() async {
        let model = PlayNextSamples.model(result: PlayNextSamples.nothingFitsResult(), ranked: 30)
        await model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "playnext-nothing-fits", size: tall) { body(model) }
    }

    @Test func noRankings() async {
        let model = PlayNextSamples.model(result: PlayNextSamples.emptyResult(), ranked: 0)
        await model.start()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "playnext-no-rankings", size: tall) { body(model) }
    }

    @Test func unavailable() async {
        await SnapshotHarness.capture(group: group, "playnext-unavailable", size: SnapSize(width: 800, height: 560)) {
            PlayNextView()
        }
    }

    // MARK: Ask Claude states

    private func askModel(_ stub: StubSecondOpinionProvider) async -> PlayNextModel {
        let model = PlayNextSamples.model(result: PlayNextSamples.richResult(), secondOpinion: stub)
        await model.start()
        await SnapshotHarness.settle(rounds: 5)
        model.askClaude()
        await SnapshotHarness.settle(rounds: 6)
        return model
    }

    @Test func askAsking() async {
        let stub = StubSecondOpinionProvider()
        stub.delay = 60
        stub.echoEngineOrder = true
        let model = await askModel(stub)
        await SnapshotHarness.capture(group: group, "playnext-ask-asking", size: wide) { body(model) }
    }

    @Test func askAgreed() async {
        let stub = StubSecondOpinionProvider(opinion: SecondOpinion(
            picks: [.init(gameID: 200, reason: "FromSoftware's open-world Souls — exactly your S/A wheelhouse.", caveat: "The 53 h figure is a focused run."),
                    .init(gameID: 201, reason: "The closest thing to Souls in 2D."),
                    .init(gameID: 203, reason: "A timeless JRPG if you want a change of pace.")],
            model: "claude", metrics: ClaudeRunMetrics(costUSD: 0.73)))
        let model = await askModel(stub)
        await SnapshotHarness.capture(group: group, "playnext-ask-agreed", size: wide) { body(model) }
    }

    @Test func askDisagreed() async {
        let stub = StubSecondOpinionProvider(opinion: SecondOpinion(
            picks: [.init(gameID: 201, reason: "For a long haul I'd start here — a tighter, more focused adventure.", caveat: "Slow first few hours."),
                    .init(gameID: 200, reason: "Superb, but a bigger time sink than it looks.")],
            model: "claude", metrics: ClaudeRunMetrics(costUSD: 0.61)))
        let model = await askModel(stub)
        await SnapshotHarness.capture(group: group, "playnext-ask-disagreed", size: wide) { body(model) }
    }

    @Test func askFailed() async {
        let stub = StubSecondOpinionProvider(error: .unavailable("Claude Code is not logged in. Run `claude` once to sign in."))
        let model = await askModel(stub)
        await SnapshotHarness.capture(group: group, "playnext-ask-failed", size: wide) { body(model) }
    }
}
#endif
