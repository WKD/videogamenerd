import Foundation
import Testing
@testable import VGN

/// Envelope decoding against recorded, scrubbed real CLI output (`recognition-cli-*`)
/// and the version parser.
struct ClaudeCLIEnvelopeTests {

    private struct Games: Decodable, Equatable {
        struct Game: Decodable, Equatable { let title: String; let year: Int? }
        let games: [Game]
    }

    @Test("Decodes a recorded text envelope")
    func textEnvelope() throws {
        let data = try Fixtures.data("recognition-cli-text.json")
        let envelope = try ClaudeCLIEnvelope.decode(from: data)
        #expect(envelope.isError == false)
        #expect(envelope.result == "OK")
        #expect(envelope.structuredOutput == nil)
        #expect(envelope.totalCostUSD != nil)
        #expect(envelope.usage?.inputTokens == 10)
    }

    @Test("Decodes a recorded structured envelope and re-decodes the payload")
    func structuredEnvelope() throws {
        let data = try Fixtures.data("recognition-cli-structured.json")
        let envelope = try ClaudeCLIEnvelope.decode(from: data)
        #expect(envelope.isError == false)
        let payload = try envelope.structuredPayload()
        let games = try JSONDecoder().decode(Games.self, from: payload)
        #expect(games.games.count == 2)
        #expect(games.games.first?.title == "Elden Ring")
        #expect(games.games.first?.year == 2022)
    }

    @Test("Prefers structured_output over the result string")
    func prefersStructured() throws {
        // result string is empty here; structured_output must be used.
        let json = FakeClaudeCLI.structuredEnvelope(json: #"{"games":[{"title":"Halo","year":2001}]}"#)
        let envelope = try ClaudeCLIEnvelope.decode(from: Data(json.utf8))
        let games = try JSONDecoder().decode(Games.self, from: envelope.structuredPayload())
        #expect(games.games == [Games.Game(title: "Halo", year: 2001)])
    }

    @Test("Surfaces is_error from a recorded error envelope")
    func errorEnvelope() throws {
        let data = try Fixtures.data("recognition-cli-error.json")
        let envelope = try ClaudeCLIEnvelope.decode(from: data)
        #expect(envelope.isError == true)
        #expect(envelope.result?.contains("max turns") == true)
    }

    @Test("Recovers the JSON object when the CLI prepends a warning line")
    func noisyPrefix() throws {
        let noisy = "warning: something\n" + FakeClaudeCLI.textEnvelope(result: "hi")
        let envelope = try ClaudeCLIEnvelope.decode(from: Data(noisy.utf8))
        #expect(envelope.result == "hi")
    }

    @Test("Throws malformedOutput on non-JSON stdout")
    func malformed() {
        #expect(throws: ClaudeCLIError.self) {
            _ = try ClaudeCLIEnvelope.decode(from: Data("not json at all".utf8))
        }
    }

    @Test("Version parsing handles the real --version line and suffixes")
    func versionParsing() {
        #expect(ClaudeCLIVersion(parsing: "2.1.277 (Claude Code)") == ClaudeCLIVersion(major: 2, minor: 1, patch: 277))
        #expect(ClaudeCLIVersion(parsing: "10.0.3") == ClaudeCLIVersion(major: 10, minor: 0, patch: 3))
        #expect(ClaudeCLIVersion(parsing: "2.1.277-beta")?.patch == 277)
        #expect(ClaudeCLIVersion(parsing: "not a version") == nil)
        #expect(ClaudeCLIVersion(parsing: "2.1") == nil)
        // Ordering.
        #expect(ClaudeCLIVersion(major: 2, minor: 1, patch: 0) > ClaudeCLIVersion(major: 2, minor: 0, patch: 999))
        #expect(ClaudeCLIVersion.minimumSupported <= ClaudeCLIVersion(major: 2, minor: 1, patch: 277))
    }
}
