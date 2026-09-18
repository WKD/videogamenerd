import Foundation

/// Options for one headless `claude -p` invocation. Generic — no recognition
/// knowledge. Defaults follow PLAN §6.2 (`--max-turns 3` because reading the file is
/// itself a tool turn; `dontAsk` permission mode).
struct ClaudeRunOptions: Sendable, Equatable {
    /// Model alias or full name, or nil to use the CLI default (PLAN §6.2: model is
    /// configurable; use the default unless clearly insufficient).
    var model: String?
    /// `--max-turns`. Image tasks need ≥ 2 (read + answer); default 3.
    var maxTurns: Int
    /// `--permission-mode`.
    var permissionMode: String
    /// Hard wall-clock timeout; on expiry the child is SIGTERM→SIGKILL'd.
    var timeout: TimeInterval
    /// Grace period between SIGTERM and SIGKILL.
    var terminationGrace: TimeInterval
    /// Cap on captured stdout bytes; exceeding it kills the child.
    var maxStdoutBytes: Int
    /// Cap on captured stderr bytes (excerpted into errors).
    var maxStderrBytes: Int

    init(
        model: String? = nil,
        maxTurns: Int = 3,
        permissionMode: String = "dontAsk",
        timeout: TimeInterval = 120,
        terminationGrace: TimeInterval = 3,
        maxStdoutBytes: Int = 4 * 1024 * 1024,
        maxStderrBytes: Int = 64 * 1024
    ) {
        self.model = model
        self.maxTurns = maxTurns
        self.permissionMode = permissionMode
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.maxStdoutBytes = maxStdoutBytes
        self.maxStderrBytes = maxStderrBytes
    }

    /// Image recognition: one tile read + answer, generous timeout for vision.
    static let imageRecognition = ClaudeRunOptions(maxTurns: 3, timeout: 120)
    /// Text-only (e.g. the Play Next "Ask Claude" second opinion, PLAN §7b): no
    /// tools, one turn, short timeout.
    static let textOnly = ClaudeRunOptions(maxTurns: 1, timeout: 90)
}

/// Cost / usage surfaced from the CLI envelope, for the progress UI (PLAN §6.2).
struct ClaudeRunMetrics: Sendable, Equatable {
    var costUSD: Double?
    var inputTokens: Int?
    var outputTokens: Int?
    var numTurns: Int?
    var durationMS: Int?
    var model: String?
}

/// A successful run: the decoded value plus metrics.
struct ClaudeCLIResult<Value: Sendable>: Sendable {
    var value: Value
    var metrics: ClaudeRunMetrics
}

/// The seam every caller depends on, so downstream is testable with a stub. Two
/// entry points: a structured (JSON-schema) call that may allow tools (image tasks
/// allow `Read`), and a no-tools text call for the future second-opinion prompt.
protocol ClaudeCLIRunning: Sendable {
    /// Run a structured call and decode the result into `Value`.
    /// - `schema`: a JSON Schema string passed as `--json-schema`.
    /// - `allowedTools`: e.g. `["Read"]` for image tasks; `[]` for text.
    /// - `files`: local files copied into the run's private working directory so the
    ///   prompt can reference them **by basename** (e.g. `Read tile.jpg`).
    func runStructured<Value: Decodable & Sendable>(
        _ type: Value.Type,
        prompt: String,
        schema: String,
        allowedTools: [String],
        files: [URL],
        options: ClaudeRunOptions
    ) async throws -> ClaudeCLIResult<Value>

    /// Run a no-tools text call; the result is the model's text output.
    func runText(
        prompt: String,
        options: ClaudeRunOptions
    ) async throws -> ClaudeCLIResult<String>

    /// Resolve and version-check the binary without running a prompt (for a Settings
    /// "Check" button). Returns the resolved path.
    func preflight() async throws -> URL
}
