import Foundation

/// Drives the local `claude` CLI headlessly (PLAN §6.2). Generic and reusable: it
/// knows nothing about recognition. Enforces the billing/safety rules — a scrubbed
/// environment (so an `ANTHROPIC_API_KEY` can never silently switch it to API
/// billing), never `--bare`, a private working directory, closed stdin, a hard
/// timeout with SIGTERM→SIGKILL, output size caps, and child-killing cancellation.
///
/// **Swift 6 concurrency:** `Process`/`FileHandle`/`Pipe` are not `Sendable`. They
/// are confined to `launch(_:)` and only crossed over `@Sendable` boundaries inside
/// small `@unchecked Sendable` boxes that are messaged solely with thread-safe
/// operations (`terminate()`, `kill(2)`, blocking `read`). Each such box documents
/// why it is safe.
struct ClaudeProcessRunner: ClaudeCLIRunning {
    private let binaryCache: ResolvedBinaryCache
    private let environmentSource: @Sendable () -> [String: String]

    init(
        resolver: ClaudeBinaryResolving = ClaudeBinaryLocator(),
        environmentSource: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.binaryCache = ResolvedBinaryCache(resolver: resolver)
        self.environmentSource = environmentSource
    }

    /// Convenience: build with an optional Settings override path.
    init(binaryOverride: String?) {
        self.init(resolver: ClaudeBinaryLocator(explicitOverride: binaryOverride))
    }

    // MARK: - Environment scrubbing

    /// The only environment keys forwarded to the child. An allowlist is used
    /// deliberately: it *guarantees* no `ANTHROPIC_*` / `CLAUDE_CODE_USE_*` provider
    /// switch (which would bill an API key or a 3P provider) can leak through, while
    /// keeping what the OAuth-logged-in CLI needs (HOME holds `~/.claude`).
    static let preservedEnvironmentKeys: Set<String> = [
        "HOME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "TMPDIR", "USER", "LOGNAME", "SHELL", "TERM",
    ]

    static func scrubbedEnvironment(from environment: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in preservedEnvironmentKeys where environment[key] != nil {
            out[key] = environment[key]
        }
        return out
    }

    // MARK: - Argument construction

    static func buildArguments(
        prompt: String,
        schema: String?,
        allowedTools: [String],
        disableAllTools: Bool,
        options: ClaudeRunOptions
    ) -> [String] {
        var args = [
            "-p", prompt,
            "--output-format", "json",
            "--max-turns", String(options.maxTurns),
            "--permission-mode", options.permissionMode,
        ]
        if let schema { args += ["--json-schema", schema] }
        if disableAllTools {
            args += ["--tools", ""]          // disable all built-in tools (text calls)
        } else if !allowedTools.isEmpty {
            args += ["--allowedTools", allowedTools.joined(separator: ",")]
        }
        if let model = options.model { args += ["--model", model] }
        return args
    }

    // MARK: - Public API

    func preflight() async throws -> URL {
        try await binaryCache.resolved()
    }

    func runStructured<Value: Decodable & Sendable>(
        _ type: Value.Type,
        prompt: String,
        schema: String,
        allowedTools: [String],
        files: [URL],
        options: ClaudeRunOptions
    ) async throws -> ClaudeCLIResult<Value> {
        let args = Self.buildArguments(
            prompt: prompt,
            schema: schema,
            allowedTools: allowedTools,
            disableAllTools: allowedTools.isEmpty,
            options: options
        )
        let stdout = try await run(arguments: args, files: files, options: options)
        let envelope = try ClaudeCLIEnvelope.decode(from: stdout)
        try Self.throwIfEnvelopeError(envelope)
        let payload = try envelope.structuredPayload()
        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: payload)
        } catch {
            throw ClaudeCLIError.malformedOutput("structured result did not decode into \(Value.self): \(error)")
        }
        return ClaudeCLIResult(value: value, metrics: Self.metrics(from: envelope, model: options.model))
    }

    func runText(prompt: String, options: ClaudeRunOptions) async throws -> ClaudeCLIResult<String> {
        let args = Self.buildArguments(
            prompt: prompt,
            schema: nil,
            allowedTools: [],
            disableAllTools: true,
            options: options
        )
        let stdout = try await run(arguments: args, files: [], options: options)
        let envelope = try ClaudeCLIEnvelope.decode(from: stdout)
        try Self.throwIfEnvelopeError(envelope)
        let text = envelope.result ?? ""
        return ClaudeCLIResult(value: text, metrics: Self.metrics(from: envelope, model: options.model))
    }

    // MARK: - Envelope helpers

    private static func throwIfEnvelopeError(_ envelope: ClaudeCLIEnvelope) throws {
        guard envelope.isError else { return }
        let message = envelope.result ?? envelope.subtype ?? "unknown error"
        if looksLikeLoginError(message) {
            throw ClaudeCLIError.notLoggedIn(detail: excerpt(message))
        }
        throw ClaudeCLIError.resultError(excerpt(message))
    }

    private static func metrics(from envelope: ClaudeCLIEnvelope, model: String?) -> ClaudeRunMetrics {
        ClaudeRunMetrics(
            costUSD: envelope.totalCostUSD,
            inputTokens: envelope.usage?.inputTokens,
            outputTokens: envelope.usage?.outputTokens,
            numTurns: envelope.numTurns,
            durationMS: envelope.durationMS,
            model: model
        )
    }

    private static func looksLikeLoginError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["not logged in", "please log in", "please run `claude`", "not authenticated",
                "authentication", "run /login", "oauth", "no credentials"]
            .contains { lower.contains($0) }
    }

    private static func excerpt(_ text: String, limit: Int = 2000) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    // MARK: - Process launch

    private func run(arguments: [String], files: [URL], options: ClaudeRunOptions) async throws -> Data {
        let binary = try await binaryCache.resolved()

        // Private working directory containing only the caller's files. Prompts must
        // reference files by basename (e.g. `Read tile.jpg`).
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vgn-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        for file in files {
            let dest = workDir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: dest)
        }

        return try await launch(binary: binary, arguments: arguments, workingDirectory: workDir, options: options)
    }

    private func launch(
        binary: URL,
        arguments: [String],
        workingDirectory: URL,
        options: ClaudeRunOptions
    ) async throws -> Data {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.scrubbedEnvironment(from: environmentSource())
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let signal = TerminationSignal()
        process.terminationHandler = { finished in signal.complete(finished.terminationStatus) }

        do {
            try process.run()
        } catch {
            throw ClaudeCLIError.launchFailed(String(describing: error))
        }

        let handle = ProcessHandle(process)
        let stdoutHandle = UncheckedSendable(stdoutPipe.fileHandleForReading)
        let stderrHandle = UncheckedSendable(stderrPipe.fileHandleForReading)

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently (avoids a full-pipe deadlock).
            async let outCapture = Self.readCapped(stdoutHandle, cap: options.maxStdoutBytes)
            async let errCapture = Self.readCapped(stderrHandle, cap: options.maxStderrBytes)

            let outcome = await Self.waitForExit(
                handle,
                signal: signal,
                timeout: options.timeout,
                grace: options.terminationGrace
            )

            let (outData, outOverflow) = await outCapture
            let (errData, _) = await errCapture

            if Task.isCancelled { throw ClaudeCLIError.cancelled }

            switch outcome {
            case .timedOut:
                throw ClaudeCLIError.timedOut(after: options.timeout)
            case .exited(let code):
                if outOverflow { throw ClaudeCLIError.outputTooLarge(limit: options.maxStdoutBytes) }
                if code != 0 {
                    let stderr = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.looksLikeLoginError(stderr) {
                        throw ClaudeCLIError.notLoggedIn(detail: Self.excerpt(stderr))
                    }
                    throw ClaudeCLIError.nonZeroExit(code: code, stderr: Self.excerpt(stderr))
                }
                return outData
            }
        } onCancel: {
            handle.terminate()
            handle.kill()
        }
    }

    private enum ExitOutcome: Sendable { case exited(Int32); case timedOut }

    private static func waitForExit(
        _ handle: ProcessHandle,
        signal: TerminationSignal,
        timeout: TimeInterval,
        grace: TimeInterval
    ) async -> ExitOutcome {
        await withTaskGroup(of: ExitOutcome?.self) { group in
            group.addTask {
                .exited(await signal.wait())
            }
            group.addTask {
                if (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil {
                    return .timedOut
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()

            guard let outcome = first else {
                // Timeout task was cancelled because termination won.
                for await _ in group {}
                return .exited(handle.terminationStatus)
            }
            if case .timedOut = outcome {
                handle.terminate()
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                handle.kill()
            }
            for await _ in group {}
            return outcome
        }
    }

    /// Blocking chunked read on a detached task, capped at `cap` bytes. Returns the
    /// (possibly truncated) data and whether the cap was exceeded.
    private static func readCapped(_ handle: UncheckedSendable<FileHandle>, cap: Int) async -> (Data, Bool) {
        await Task.detached(priority: .utility) {
            var data = Data()
            var overflow = false
            while true {
                let chunk = (try? handle.value.read(upToCount: 64 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                if data.count >= cap {
                    overflow = true
                    continue
                }
                let room = cap - data.count
                if chunk.count > room {
                    data.append(chunk.prefix(room))
                    overflow = true
                } else {
                    data.append(chunk)
                }
            }
            return (data, overflow)
        }.value
    }
}

// MARK: - Concurrency support

/// Caches the resolved, version-checked binary URL so per-tile calls don't re-run
/// `command -v` / `--version` each time.
private actor ResolvedBinaryCache {
    private let resolver: ClaudeBinaryResolving
    private var cached: URL?

    init(resolver: ClaudeBinaryResolving) { self.resolver = resolver }

    func resolved() throws -> URL {
        if let cached { return cached }
        let url = try resolver.resolve()
        cached = url
        return url
    }
}

/// Confines a launched `Process` so it can cross the `@Sendable` cancel/timeout
/// boundary. Safe: only `terminate()` and `kill(2)` are sent across threads (both
/// documented thread-safe), and the configuration is never mutated after `run()`.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }

    var terminationStatus: Int32 { process.isRunning ? 0 : process.terminationStatus }

    func terminate() {
        if process.isRunning { process.terminate() }   // SIGTERM
    }

    func kill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        Foundation.kill(pid, SIGKILL)
    }
}

/// A thread-safe latch bridging `Process.terminationHandler` to `async`. The handler
/// is installed before `run()`, so no exit is ever missed.
private final class TerminationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var status: Int32 = 0
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func complete(_ code: Int32) {
        let toResume: [CheckedContinuation<Int32, Never>]
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        status = code
        toResume = waiters
        waiters = []
        lock.unlock()
        for continuation in toResume { continuation.resume(returning: code) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished {
                let code = status
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Minimal box to carry a non-`Sendable` value across a `@Sendable` boundary when the
/// programmer guarantees safe use (documented at each call site).
private final class UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
