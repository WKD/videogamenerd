import Foundation

/// Typed failures from driving the local `claude` CLI (PLAN §6.2, §11). Every case
/// carries enough context for a Settings row or a per-tile progress line to explain
/// itself, without leaking prompts or credentials.
enum ClaudeCLIError: Error, Sendable, Equatable {
    /// No `claude` binary found: neither the override, `command -v`, nor any known
    /// install location resolved. Carries the paths that were tried.
    case notInstalled(searched: [String])
    /// The binary ran but reported it is not authenticated (no subscription login).
    case notLoggedIn(detail: String)
    /// `claude --version` reported a version below the minimum this app supports.
    case versionTooOld(found: String, minimum: String)
    /// `claude --version` produced output we could not parse into a version.
    case unparsableVersion(String)
    /// The child did not finish within the timeout; it was SIGTERM→SIGKILL'd.
    case timedOut(after: TimeInterval)
    /// The child exited non-zero. Carries the exit code and a bounded stderr excerpt.
    case nonZeroExit(code: Int32, stderr: String)
    /// stdout was not the expected `--output-format json` envelope, or the structured
    /// result did not decode into the caller's type.
    case malformedOutput(String)
    /// The envelope decoded but `is_error` was true (the model/tooling reported a
    /// failure). Carries the envelope's own message.
    case resultError(String)
    /// The process could not be launched at all (bad path, permissions).
    case launchFailed(String)
    /// The output exceeded the configured size cap; the child was killed.
    case outputTooLarge(limit: Int)
    /// The surrounding task was cancelled; the child was killed.
    case cancelled

    /// A short, user-facing description safe to show in a progress row (no prompt,
    /// no credentials).
    var shortDescription: String {
        switch self {
        case .notInstalled:
            return "Claude Code is not installed or could not be found."
        case .notLoggedIn:
            return "Claude Code is not logged in. Run `claude` once to sign in."
        case .versionTooOld(let found, let minimum):
            return "Claude Code \(found) is too old (need \(minimum) or newer)."
        case .unparsableVersion(let raw):
            return "Could not read the Claude Code version (\(raw))."
        case .timedOut(let after):
            return "The recognition call timed out after \(Int(after)) s."
        case .nonZeroExit(let code, _):
            return "Claude Code exited with code \(code)."
        case .malformedOutput:
            return "Claude Code returned output that could not be read."
        case .resultError(let message):
            return "Claude Code reported an error: \(message)"
        case .launchFailed(let message):
            return "Could not launch Claude Code: \(message)."
        case .outputTooLarge(let limit):
            return "Claude Code output exceeded \(limit) bytes."
        case .cancelled:
            return "Cancelled."
        }
    }
}
