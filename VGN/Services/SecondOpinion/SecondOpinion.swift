import Foundation

/// Claude's re-ranking of the Play Next shortlist (PLAN §7b "Ask Claude"). A plain
/// value the UI shows in a "Claude" column beside the engine's own order. Produced
/// only on demand, never automatically, and only from a ``SecondOpinionRequest``
/// (the sole data that may leave the app).
struct SecondOpinion: Sendable, Equatable {
    /// One re-ranked candidate. `gameID` is always one of the shortlist ids the
    /// request carried — foreign ids are discarded before this value is built.
    struct Pick: Sendable, Equatable, Identifiable {
        var gameID: Int64
        /// A 1–2 sentence, human reason (trimmed).
        var reason: String
        /// An optional caveat ("slow first 10 hours", "needs the first game").
        var caveat: String?

        var id: Int64 { gameID }

        init(gameID: Int64, reason: String, caveat: String? = nil) {
            self.gameID = gameID
            self.reason = reason
            self.caveat = caveat
        }
    }

    /// Claude's order, hero first, at most five.
    var picks: [Pick]
    /// The model that answered (from the CLI envelope, when known).
    var model: String?
    /// Cost / token usage from the run, for a subtle footnote.
    var metrics: ClaudeRunMetrics?

    init(picks: [Pick], model: String? = nil, metrics: ClaudeRunMetrics? = nil) {
        self.picks = picks
        self.model = model
        self.metrics = metrics
    }
}

// MARK: - Provider seam

/// The seam the Play Next model asks for a second opinion through (PLAN §7b:
/// "Behind a `SecondOpinioning` protocol so tests use a stub and an API-key variant
/// stays a drop-in"). Only a ``SecondOpinionRequest`` crosses this boundary.
protocol SecondOpinionProviding: Sendable {
    func secondOpinion(for request: SecondOpinionRequest) async throws -> SecondOpinion
}

// MARK: - Failures

/// A friendly, already-classified failure for the "Ask Claude" UI (PLAN §7b:
/// "if the CLI is missing, logged out or times out, the button explains why").
/// Every ``ClaudeCLIError`` maps to one of these; the UI decides whether to offer
/// a Settings link from ``suggestsSettings``.
enum SecondOpinionError: Error, Sendable, Equatable {
    /// The CLI is missing, too old, or not signed in — the user must fix setup.
    case unavailable(String)
    /// A transient run failure (timeout, non-zero exit, unreadable output).
    case failed(String)
    /// The response decoded but held no valid shortlist ids.
    case empty
    /// The request was cancelled by the user.
    case cancelled

    /// A one-line, user-facing message (no prompt, no credentials).
    var message: String {
        switch self {
        case .unavailable(let detail): return detail
        case .failed(let detail): return detail
        case .empty: return "Claude didn't rank any of these games."
        case .cancelled: return "Cancelled."
        }
    }

    /// Whether the UI should offer a link to Settings (setup problem, not a fluke).
    var suggestsSettings: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Classify a ``ClaudeCLIError`` into a friendly second-opinion failure.
    static func from(_ error: ClaudeCLIError) -> SecondOpinionError {
        switch error {
        case .notInstalled, .notLoggedIn, .versionTooOld, .unparsableVersion:
            return .unavailable(error.shortDescription)
        case .cancelled:
            return .cancelled
        case .timedOut, .nonZeroExit, .malformedOutput, .resultError,
             .launchFailed, .outputTooLarge:
            return .failed(error.shortDescription)
        }
    }

    /// Map any thrown error into a second-opinion failure.
    static func wrap(_ error: any Error) -> SecondOpinionError {
        if let e = error as? SecondOpinionError { return e }
        if let e = error as? ClaudeCLIError { return .from(e) }
        if error is CancellationError { return .cancelled }
        return .failed((error as NSError).localizedDescription)
    }
}
