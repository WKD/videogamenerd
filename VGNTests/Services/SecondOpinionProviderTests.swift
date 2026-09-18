import Foundation
import Testing
@testable import VGN

/// The "Ask Claude" provider (PLAN §7b): validation (foreign ids discarded, dupes,
/// >5, empty), prompt-contains-only-request-data, error mapping, the text fallback,
/// and decoding of the recorded live envelope.
struct SecondOpinionProviderTests {

    // MARK: - Validation

    private func pick(_ id: Int64, _ reason: String = "r", caveat: String? = nil)
        -> SecondOpinionPrompt.Response.Pick {
        SecondOpinionPrompt.Response.Pick(id: id, reason: reason, caveat: caveat)
    }

    @Test func discardsForeignIDs() throws {
        let out = try ClaudeSecondOpinionProvider.validate(
            [pick(1), pick(99), pick(2)], allowedIDs: [1, 2], model: nil, metrics: nil)
        #expect(out.picks.map(\.gameID) == [1, 2])
    }

    @Test func dropsDuplicates() throws {
        let out = try ClaudeSecondOpinionProvider.validate(
            [pick(1), pick(1), pick(2)], allowedIDs: [1, 2, 3], model: nil, metrics: nil)
        #expect(out.picks.map(\.gameID) == [1, 2])
    }

    @Test func capsAtFive() throws {
        let raw = (1...8).map { pick(Int64($0)) }
        let out = try ClaudeSecondOpinionProvider.validate(
            raw, allowedIDs: Set((1...8).map(Int64.init)), model: nil, metrics: nil)
        #expect(out.picks.count == 5)
        #expect(out.picks.map(\.gameID) == [1, 2, 3, 4, 5])
    }

    @Test func trimsReasonsAndDropsEmptyCaveats() throws {
        let out = try ClaudeSecondOpinionProvider.validate(
            [pick(1, "  good pick \n", caveat: "  "), pick(2, "x", caveat: " slow start ")],
            allowedIDs: [1, 2], model: nil, metrics: nil)
        #expect(out.picks[0].reason == "good pick")
        #expect(out.picks[0].caveat == nil)
        #expect(out.picks[1].caveat == "slow start")
    }

    @Test func emptyAfterFilteringThrows() {
        #expect(throws: SecondOpinionError.empty) {
            _ = try ClaudeSecondOpinionProvider.validate(
                [pick(99), pick(100)], allowedIDs: [1, 2], model: nil, metrics: nil)
        }
    }

    // MARK: - Runner path (structured, no tools)

    @Test func structuredHappyPathUsesNoTools() async throws {
        let runner = FakeClaudeRunner()
        runner.structuredJSON = #"{"picks":[{"id":2,"reason":"Best fit"},{"id":1,"reason":"Also good","caveat":"slow"}]}"#
        let provider = ClaudeSecondOpinionProvider(runner: runner, model: nil)
        let request = Self.sampleRequest(shortlist: [1, 2])
        let opinion = try await provider.secondOpinion(for: request)

        #expect(runner.lastAllowedTools.isEmpty)               // no tools (PLAN §7b)
        #expect(runner.lastSchema == SecondOpinionPrompt.schema)
        #expect(opinion.picks.map(\.gameID) == [2, 1])
        #expect(opinion.picks[1].caveat == "slow")
        #expect(opinion.model == "claude-test")
        #expect(opinion.metrics?.costUSD == 0.02)
    }

    @Test func runnerForeignIDsAreDiscarded() async throws {
        let runner = FakeClaudeRunner()
        runner.structuredJSON = #"{"picks":[{"id":777,"reason":"nope"},{"id":1,"reason":"yes"}]}"#
        let provider = ClaudeSecondOpinionProvider(runner: runner)
        let opinion = try await provider.secondOpinion(for: Self.sampleRequest(shortlist: [1, 2]))
        #expect(opinion.picks.map(\.gameID) == [1])
    }

    // MARK: - Text fallback (malformed structured → parse a fenced block)

    @Test func fallsBackToTextOnMalformedStructured() async throws {
        let runner = FakeClaudeRunner()
        runner.structuredError = .malformedOutput("bad")
        runner.textResult = """
        Here is my ranking:
        ```json
        {"picks":[{"id":2,"reason":"top"}]}
        ```
        Hope that helps.
        """
        let provider = ClaudeSecondOpinionProvider(runner: runner)
        let opinion = try await provider.secondOpinion(for: Self.sampleRequest(shortlist: [1, 2]))
        #expect(runner.textCalls == 1)
        #expect(opinion.picks.map(\.gameID) == [2])
    }

    @Test func extractsBalancedJSONObject() {
        let text = "prose {\"a\": {\"b\": \"}\"}} trailing"
        #expect(ClaudeSecondOpinionProvider.extractJSONObject(from: text) == "{\"a\": {\"b\": \"}\"}}")
        #expect(ClaudeSecondOpinionProvider.extractJSONObject(from: "no json here") == nil)
    }

    // MARK: - Error mapping (every ClaudeCLIError → a friendly failure)

    @Test func mapsEveryClaudeCLIError() {
        let cases: [(ClaudeCLIError, Bool)] = [   // (error, suggestsSettings)
            (.notInstalled(searched: ["/x"]), true),
            (.notLoggedIn(detail: "d"), true),
            (.versionTooOld(found: "1", minimum: "2"), true),
            (.unparsableVersion("x"), true),
            (.timedOut(after: 90), false),
            (.nonZeroExit(code: 1, stderr: "e"), false),
            (.malformedOutput("m"), false),
            (.resultError("r"), false),
            (.launchFailed("l"), false),
            (.outputTooLarge(limit: 10), false),
            (.cancelled, false),
        ]
        for (error, settings) in cases {
            let mapped = SecondOpinionError.from(error)
            #expect(!mapped.message.isEmpty)
            if case .cancelled = error {
                #expect(mapped == .cancelled)
            } else {
                #expect(mapped.suggestsSettings == settings, "for \(error)")
            }
        }
    }

    @Test func structuredErrorPropagatesAsFriendlyFailure() async throws {
        let runner = FakeClaudeRunner()
        runner.structuredError = .notLoggedIn(detail: "log in")
        let provider = ClaudeSecondOpinionProvider(runner: runner)
        await #expect(throws: SecondOpinionError.unavailable(ClaudeCLIError.notLoggedIn(detail: "log in").shortDescription)) {
            _ = try await provider.secondOpinion(for: Self.sampleRequest(shortlist: [1]))
        }
    }

    // MARK: - Recorded live envelope decodes through the provider's shape

    @Test func decodesRecordedLiveEnvelope() throws {
        let data = try Fixtures.data("secondopinion-live-envelope.json")
        let envelope = try ClaudeCLIEnvelope.decode(from: data)
        #expect(envelope.isError == false)
        let payload = try envelope.structuredPayload()
        let response = try JSONDecoder().decode(SecondOpinionPrompt.Response.self, from: payload)
        let opinion = try ClaudeSecondOpinionProvider.validate(
            response.picks, allowedIDs: [200, 201, 202],
            model: envelope.usage != nil ? "recorded" : nil, metrics: nil)
        #expect(opinion.picks.map(\.gameID) == [200, 201, 202])
        #expect(opinion.picks.allSatisfy { !$0.reason.isEmpty })
        #expect(envelope.totalCostUSD != nil)
    }

    // MARK: - Prompt carries ONLY request data (no library leak)

    @MainActor
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct PromptLeakTests {
        @Test func promptContainsOnlyRequestData() async throws {
            let db = try await TestDB.makeSeeded()
            let lib = LibraryStore(db)
            let rec = RecommendationStore(db)

            // Ranked taste + a "didn't click".
            _ = try await lib.addGame(GameDraft(title: "Masterpiece", igdbID: 1,
                                                platformIDs: ["ps4"], played: true, tierID: 1)).gameID
            _ = try await lib.addGame(GameDraft(title: "Awful", igdbID: 2,
                                                platformIDs: ["ps4"], played: true, tierID: 6)).gameID
            // The one candidate that should be shortlisted.
            let cand = try await lib.addGame(GameDraft(title: "Backlog Pick", igdbID: 3,
                                                       platformIDs: ["ps5"], owned: true)).gameID
            try await lib.updateMetadata(gameID: cand, MetadataPatch(ttbNormallyS: Rec.hours(20)))
            // A game that must NEVER reach the prompt: unowned, unplayed, unranked.
            _ = try await lib.addGame(GameDraft(title: "ZZZSecretGame", igdbID: 4,
                                                platformIDs: ["ps4"])).gameID

            let result = try await rec.recommend(bracket: TimeBracket(preset: .month))
            let request = try await rec.secondOpinionRequest(for: result)

            let runner = FakeClaudeRunner()
            runner.structuredJSON = "{\"picks\":[{\"id\":\(cand),\"reason\":\"Great fit.\"}]}"
            let provider = ClaudeSecondOpinionProvider(runner: runner)
            _ = try await provider.secondOpinion(for: request)

            let prompt = try #require(runner.lastPrompt)
            #expect(prompt.contains("Backlog Pick"))
            #expect(prompt.contains("Masterpiece"))
            #expect(prompt.contains("Awful"))
            #expect(!prompt.contains("ZZZSecretGame"))
        }
    }

    // MARK: - Fixtures

    static func sampleRequest(shortlist ids: [Int64]) -> SecondOpinionRequest {
        SecondOpinionRequest(
            bracket: "A long haul",
            completionist: false,
            topRanked: [.init(title: "Bloodborne", tier: "S", globalPosition: 1)],
            didntClick: [.init(title: "Heavy Rain", tier: "F")],
            shortlist: ids.enumerated().map { i, id in
                .init(id: id, title: "Game \(id)", platform: "ps5", format: "digital",
                      estimateHours: 20, status: "backlog", engineRank: i + 1)
            },
            engineOrdering: ids)
    }
}
