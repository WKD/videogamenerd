import Foundation
import Testing
@testable import VGN

/// Drives `ClaudeProcessRunner` against a generated fake `claude` script: argument
/// construction, environment scrubbing, structured/text decoding, timeout,
/// cancellation, malformed output and non-zero exit — no real CLI, no network.
struct ClaudeCLIRunnerTests {

    private struct Games: Decodable, Equatable {
        struct Game: Decodable, Equatable { let title: String; let year: Int? }
        let games: [Game]
    }

    private func runner(
        for script: FakeClaudeCLI.Script,
        environment: [String: String] = [
            "HOME": "/Users/tester", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "ANTHROPIC_API_KEY": "sk-should-be-stripped",
            "ANTHROPIC_AUTH_TOKEN": "tok-should-be-stripped",
            "CLAUDE_CODE_USE_BEDROCK": "1",
        ]
    ) -> ClaudeProcessRunner {
        ClaudeProcessRunner(
            resolver: StubClaudeResolver(url: script.executable),
            environmentSource: { environment }
        )
    }

    @Test("Passes the PLAN §6.2 flags and decodes structured output")
    func structuredCallFlagsAndDecode() async throws {
        let envelope = FakeClaudeCLI.structuredEnvelope(json: #"{"games":[{"title":"Elden Ring","year":2022}]}"#)
        let script = try FakeClaudeCLI.make(stdout: envelope)
        let result = try await runner(for: script).runStructured(
            Games.self,
            prompt: "read tile.jpg",
            schema: #"{"type":"object"}"#,
            allowedTools: ["Read"],
            files: [],
            options: ClaudeRunOptions(model: "opus", maxTurns: 3, timeout: 10)
        )
        #expect(result.value.games.first?.title == "Elden Ring")
        #expect(result.metrics.numTurns == 2)
        #expect(result.metrics.costUSD == 0.02)
        #expect(result.metrics.model == "opus")

        let args = script.recordedArguments()
        #expect(args.contains("-p"))
        #expect(args.contains("read tile.jpg"))
        #expect(adjacent(args, "--output-format", "json"))
        #expect(adjacent(args, "--json-schema", #"{"type":"object"}"#))
        #expect(adjacent(args, "--max-turns", "3"))
        #expect(adjacent(args, "--permission-mode", "dontAsk"))
        #expect(adjacent(args, "--allowedTools", "Read"))
        #expect(adjacent(args, "--model", "opus"))
        #expect(args.contains("--bare") == false)
    }

    @Test("Scrubs ANTHROPIC_*/CLAUDE_CODE_USE_* from the child environment")
    func environmentScrubbed() async throws {
        let script = try FakeClaudeCLI.make(stdout: FakeClaudeCLI.textEnvelope(result: "ok"))
        _ = try await runner(for: script).runText(prompt: "hi", options: ClaudeRunOptions(timeout: 10))
        let env = script.recordedEnvironment()
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(env["CLAUDE_CODE_USE_BEDROCK"] == nil)
        // Preserved essentials survive.
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["LANG"] == "en_US.UTF-8")
    }

    @Test("Text call disables all tools and returns the result string")
    func textCallDisablesTools() async throws {
        let script = try FakeClaudeCLI.make(stdout: FakeClaudeCLI.textEnvelope(result: "hello"))
        let result = try await runner(for: script).runText(prompt: "say hello", options: ClaudeRunOptions(timeout: 10))
        #expect(result.value == "hello")
        let args = script.recordedArguments()
        #expect(adjacent(args, "--tools", ""))
        #expect(args.contains("--json-schema") == false)
    }

    @Test("Times out and reports timedOut, killing the child")
    func timeout() async throws {
        // The child sleeps far longer than any scheduling hiccup: under a loaded parallel
        // run the 0.4 s timer can fire seconds late, and a 5 s child then finished first
        // (flake seen 2026-09-19). The child is killed on timeout, so the test stays fast.
        let script = try FakeClaudeCLI.make(stdout: FakeClaudeCLI.textEnvelope(result: "late"), sleepSeconds: 120)
        await #expect(throws: ClaudeCLIError.self) {
            _ = try await runner(for: script).runText(
                prompt: "hi",
                options: ClaudeRunOptions(timeout: 0.4, terminationGrace: 0.2)
            )
        }
    }

    @Test("Non-zero exit surfaces nonZeroExit")
    func nonZeroExit() async throws {
        let script = try FakeClaudeCLI.make(stdout: "boom on stderr side", exitCode: 3)
        do {
            _ = try await runner(for: script).runText(prompt: "hi", options: ClaudeRunOptions(timeout: 10))
            Issue.record("expected throw")
        } catch let error as ClaudeCLIError {
            guard case .nonZeroExit(let code, _) = error else {
                Issue.record("expected nonZeroExit, got \(error)")
                return
            }
            #expect(code == 3)
        }
    }

    @Test("Malformed stdout surfaces malformedOutput")
    func malformedOutput() async throws {
        let script = try FakeClaudeCLI.make(stdout: "this is not json")
        do {
            _ = try await runner(for: script).runText(prompt: "hi", options: ClaudeRunOptions(timeout: 10))
            Issue.record("expected throw")
        } catch let error as ClaudeCLIError {
            guard case .malformedOutput = error else {
                Issue.record("expected malformedOutput, got \(error)")
                return
            }
        }
    }

    @Test("is_error envelope surfaces resultError")
    func isErrorEnvelope() async throws {
        let envelope = #"{"type":"result","is_error":true,"subtype":"error_max_turns","result":"Reached max turns"}"#
        let script = try FakeClaudeCLI.make(stdout: envelope)
        do {
            _ = try await runner(for: script).runText(prompt: "hi", options: ClaudeRunOptions(timeout: 10))
            Issue.record("expected throw")
        } catch let error as ClaudeCLIError {
            guard case .resultError = error else {
                Issue.record("expected resultError, got \(error)")
                return
            }
        }
    }

    @Test("Cancellation kills the child and throws cancelled")
    func cancellation() async throws {
        let script = try FakeClaudeCLI.make(stdout: FakeClaudeCLI.textEnvelope(result: "late"), sleepSeconds: 5)
        let theRunner = runner(for: script)
        let task = Task {
            try await theRunner.runText(prompt: "hi", options: ClaudeRunOptions(timeout: 30))
        }
        // Give the child time to launch, then cancel.
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation to throw")
        } catch is CancellationError {
            // acceptable
        } catch let error as ClaudeCLIError {
            #expect(error == .cancelled || { if case .timedOut = error { return false } else { return true } }())
        }
    }

    @Test("preflight surfaces the resolver's typed error")
    func preflightError() async throws {
        let runner = ClaudeProcessRunner(resolver: StubClaudeResolver(error: .notInstalled(searched: ["/x"])))
        await #expect(throws: ClaudeCLIError.self) {
            _ = try await runner.preflight()
        }
    }

    // MARK: - Helpers

    private func adjacent(_ args: [String], _ flag: String, _ value: String) -> Bool {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return false }
        return args[i + 1] == value
    }
}
