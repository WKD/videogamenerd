import Foundation
import Testing
@testable import VGN

/// A ``DiscoverBackend`` that also serves a taste half, wrapping ``FakeDiscoverBackend``.
private struct TasteDiscoverBackend: DiscoverBackend {
    let inner: FakeDiscoverBackend
    let taste: SecondOpinionTaste
    func rankedGames() async throws -> [RankedGame] { try await inner.rankedGames() }
    func pool(limit: Int) async throws -> [RomCatalogEntry] { try await inner.pool(limit: limit) }
    func playedSystems() async throws -> Set<String> { try await inner.playedSystems() }
    func exemplarInfo(ids: [Int64]) async throws -> [Int64: ExemplarInfo] { try await inner.exemplarInfo(ids: ids) }
    func setNotInterested(catalogID: Int64) async throws { try await inner.setNotInterested(catalogID: catalogID) }
    func secondOpinionTaste() async throws -> SecondOpinionTaste { taste }
}

/// "Ask Claude" on the "From the vault" row (PLAN §7b): the model's state machine over the stub
/// provider only — never the real `claude` CLI, no process, no DB.
@MainActor
@Suite(.serialized)
struct DiscoverAskClaudeTests {

    private func entry(_ id: Int64) -> RomCatalogEntry {
        RomCatalogEntry(id: id, source: "batocera", system: "snes", platformID: "snes",
                        relativePath: "./G\(id).zip", name: "Game \(id)", genre: "Platform")
    }
    private func ranked(_ id: Int64) -> RankedGame {
        RankedGame(id: id, igdbID: nil, score: 0.8, traits: [GameTrait(kind: .genre, value: "Platform")])
    }

    private func loadedModel(stub: StubSecondOpinionProvider?, poolSize: Int = 14,
                             bracket: TimeBracket? = TimeBracket(shelf: .weekend)) async -> DiscoverModel {
        let inner = FakeDiscoverBackend(ranked: (1...10).map(ranked), pool: (1...Int64(poolSize)).map(entry))
        let backend = TasteDiscoverBackend(
            inner: inner,
            taste: SecondOpinionTaste(topRanked: [.init(title: "Bloodborne", tier: "S", globalPosition: 1)],
                                      didntClick: []))
        let model = DiscoverModel(backend: backend, cardCount: 8, deadlineMonthsLeft: { nil },
                                  bracket: bracket, secondOpinion: stub)
        model.load()
        await waitUntil { model.hasLoaded && !model.items.isEmpty }
        return model
    }

    @Test(.timeLimit(.minutes(1)))
    func noProviderMeansNoButton() async {
        let model = await loadedModel(stub: nil)
        #expect(model.canAskClaude == false)
        model.askClaude()
        #expect(model.secondOpinionState == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func shortlistIsTopTenAndCardsStayCapped() async {
        let model = await loadedModel(stub: StubSecondOpinionProvider())
        #expect(model.items.count == 8)
        #expect(model.shortlist.count == DiscoverSecondOpinion.shortlistSize)
        #expect(Array(model.shortlist.prefix(8).map(\.id)) == model.items.map(\.entry.id))
    }

    @Test(.timeLimit(.minutes(1)))
    func askSendsTheVaultShortlistAndCachesPerShortlistAndBracket() async throws {
        let stub = StubSecondOpinionProvider()
        let model = await loadedModel(stub: stub)
        let ids = model.shortlist.map(\.id)
        stub.opinion = SecondOpinion(picks: [
            .init(gameID: ids[2], reason: "Tight.", caveat: "Aged controls"),
            .init(gameID: 9_999, reason: "Invented."),            // outside the shortlist
            .init(gameID: ids[0], reason: "Classic.")])
        #expect(model.canAskClaude)
        model.askClaude()
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }
        guard case let .result(opinion) = model.secondOpinionState else {
            Issue.record("no result"); return
        }
        #expect(opinion.picks.map(\.gameID) == [ids[2], ids[0]])   // foreign id discarded
        #expect(model.secondOpinionAgreesOnTop == false)
        let request = try #require(stub.lastRequest)
        #expect(request.kind == .vault)
        #expect(request.shortlist.map(\.id) == ids)
        #expect(request.topRanked.first?.title == "Bloodborne")
        #expect(request.bracket == TimeBracket(shelf: .weekend).label)
        #expect(stub.callCount == 1)

        // Same shortlist + bracket → cached for the session, no second call.
        model.dismissSecondOpinion()
        #expect(model.secondOpinionState == .idle)
        model.askClaude()
        #expect(stub.callCount == 1)
        if case .result = model.secondOpinionState {} else { Issue.record("not served from cache") }

        // A different bracket is a different key: the showing answer goes stale, a new ask runs.
        model.setBracket(TimeBracket(shelf: .epic))
        await waitUntil { model.secondOpinionState == .idle && model.currentSecondOpinionKey.bracket == TimeBracket(shelf: .epic) }
        await waitUntil { !model.isLoading }
        model.askClaude()
        await waitUntil { stub.callCount == 2 }
        #expect(stub.callCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func agreementOnTopIsDetected() async {
        let stub = StubSecondOpinionProvider()
        let model = await loadedModel(stub: stub)
        stub.opinion = .picks([model.shortlist[0].id, model.shortlist[1].id])
        model.askClaude()
        await waitUntil { if case .result = model.secondOpinionState { return true }; return false }
        #expect(model.secondOpinionAgreesOnTop)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingCLIExplainsAndOffersSettings() async {
        let stub = StubSecondOpinionProvider(error: .unavailable("Claude Code isn't installed."))
        let model = await loadedModel(stub: stub)
        model.askClaude()
        await waitUntil { if case .failed = model.secondOpinionState { return true }; return false }
        guard case let .failed(error) = model.secondOpinionState else {
            Issue.record("expected failure"); return
        }
        #expect(error.message == "Claude Code isn't installed.")
        #expect(error.suggestsSettings)
        // The engine's order stands.
        #expect(model.items.count == 8)
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutIsAFailureWithoutSettingsLink() async {
        let stub = StubSecondOpinionProvider(error: .failed("Claude Code timed out."))
        let model = await loadedModel(stub: stub)
        model.askClaude()
        await waitUntil { if case .failed = model.secondOpinionState { return true }; return false }
        guard case let .failed(error) = model.secondOpinionState else {
            Issue.record("expected failure"); return
        }
        #expect(error.suggestsSettings == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelReturnsToIdleAndCachesNothing() async {
        let stub = StubSecondOpinionProvider(opinion: .picks([1]))
        stub.delay = 5
        let model = await loadedModel(stub: stub)
        model.askClaude()
        #expect(model.secondOpinionState == .asking)
        model.cancelSecondOpinion()
        #expect(model.secondOpinionState == .idle)
        // Nothing cached: a new ask calls the provider again.
        stub.delay = 0
        model.askClaude()
        await waitUntil { stub.callCount == 2 }
        #expect(stub.callCount == 2)
    }
}
