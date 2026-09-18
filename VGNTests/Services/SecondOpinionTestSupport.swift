import Foundation
@testable import VGN

/// An in-memory ``ClaudeCLIRunning`` for the second-opinion tests: it records the
/// prompt it was handed and returns a scripted structured/text result or throws a
/// chosen ``ClaudeCLIError`` — no subprocess, no network.
final class FakeClaudeRunner: ClaudeCLIRunning, @unchecked Sendable {
    /// JSON decoded into the caller's structured `Value` (usually a picks object).
    var structuredJSON: String?
    /// If set, `runStructured` throws this instead.
    var structuredError: ClaudeCLIError?
    /// Text returned by `runText` (used on the fallback path).
    var textResult: String?
    var textError: ClaudeCLIError?
    var metrics = ClaudeRunMetrics(costUSD: 0.02, inputTokens: 100, outputTokens: 60,
                                   numTurns: 2, durationMS: 9000, model: "claude-test")

    private(set) var lastPrompt: String?
    private(set) var lastSchema: String?
    private(set) var lastAllowedTools: [String] = []
    private(set) var structuredCalls = 0
    private(set) var textCalls = 0

    func runStructured<Value: Decodable & Sendable>(
        _ type: Value.Type, prompt: String, schema: String,
        allowedTools: [String], files: [URL], options: ClaudeRunOptions
    ) async throws -> ClaudeCLIResult<Value> {
        structuredCalls += 1
        lastPrompt = prompt
        lastSchema = schema
        lastAllowedTools = allowedTools
        if let structuredError { throw structuredError }
        guard let json = structuredJSON, let data = json.data(using: .utf8) else {
            throw ClaudeCLIError.malformedOutput("no scripted structured output")
        }
        let value = try JSONDecoder().decode(Value.self, from: data)
        return ClaudeCLIResult(value: value, metrics: metrics)
    }

    func runText(prompt: String, options: ClaudeRunOptions) async throws -> ClaudeCLIResult<String> {
        textCalls += 1
        lastPrompt = prompt
        if let textError { throw textError }
        return ClaudeCLIResult(value: textResult ?? "", metrics: metrics)
    }

    func preflight() async throws -> URL { URL(fileURLWithPath: "/fake/claude") }
}

extension SecondOpinion {
    /// A quick picks-only opinion for previews / tests.
    static func picks(_ ids: [Int64], model: String? = "stub") -> SecondOpinion {
        SecondOpinion(picks: ids.map { Pick(gameID: $0, reason: "Fits your taste and time.") },
                      model: model)
    }
}
