import Foundation

/// A scripted ``SecondOpinionProviding`` for previews and tests, and a safe default
/// when the container hasn't wired the live provider yet. Every output is settable
/// and every call is recorded, so a test can script agreement, disagreement, a
/// failure, a cancellation, or a slow answer — with no process and no network.
final class StubSecondOpinionProvider: SecondOpinionProviding, @unchecked Sendable {
    /// What the next call returns (unless `error` is set). Ids outside the shortlist
    /// are still filtered by the caller, so a preview can pass raw picks.
    var opinion: SecondOpinion?
    /// When set, the next call throws this instead of returning `opinion`.
    var error: SecondOpinionError?
    /// An artificial delay (seconds) before answering, for spinner/cancel tests.
    var delay: Double = 0
    /// If true, the answer echoes the request's engine ordering (used by previews
    /// so the "Claude" column mirrors the shortlist when no `opinion` is set).
    var echoEngineOrder = false

    private(set) var callCount = 0
    private(set) var lastRequest: SecondOpinionRequest?

    init(opinion: SecondOpinion? = nil, error: SecondOpinionError? = nil) {
        self.opinion = opinion
        self.error = error
    }

    func secondOpinion(for request: SecondOpinionRequest) async throws -> SecondOpinion {
        callCount += 1
        lastRequest = request
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
        if let error { throw error }
        if let opinion { return opinion }
        if echoEngineOrder {
            let picks = request.shortlist.map {
                SecondOpinion.Pick(gameID: $0.id, reason: "A solid fit for your taste and time.")
            }
            return SecondOpinion(picks: Array(picks.prefix(5)), model: "stub")
        }
        throw SecondOpinionError.empty
    }
}
