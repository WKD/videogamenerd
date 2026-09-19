import Foundation

/// The retry rule of PLAN §14.1 rule 3 / §13.1 rule 4, **encoded as data** so it is a
/// pure decision table with tests rather than scattered `if`s:
///
///  - **200-range** → proceed.
///  - **401** → refresh the token **once**; a second 401 after the refresh → stop.
///  - **429** → honour `Retry-After` **once**, then the sync ends; a second 429 → stop.
///  - **everything else** (403 / HTML / captcha / unknown envelope / 5xx) → stop.
///
/// There are no loops: at most one token refresh and at most one 429 wait across a
/// whole sync.
enum ImportRetryDecision: Sendable, Equatable {
    /// The response is usable.
    case proceed
    /// A 401 on a fresh-enough token: refresh once and retry this one request.
    case refreshTokenOnce
    /// A 429 with an optional server delay: wait once, retry this one request, and
    /// then the sync ends regardless of the outcome.
    case waitRetryAfterThenEnd(TimeInterval?)
    /// Stop the sync now and surface the reason.
    case stop
}

struct ImportRetryPolicy: Sendable {
    /// Decide what to do with a response.
    /// - Parameters:
    ///   - status: HTTP status of the response just received.
    ///   - retryAfter: parsed `Retry-After`, if any.
    ///   - hasRefreshedToken: has this sync already spent its single 401 refresh?
    ///   - hasWaited429: has this sync already spent its single 429 wait?
    func decide(status: Int,
                retryAfter: TimeInterval?,
                hasRefreshedToken: Bool,
                hasWaited429: Bool) -> ImportRetryDecision {
        switch status {
        case 200...299:
            return .proceed
        case 401:
            return hasRefreshedToken ? .stop : .refreshTokenOnce
        case 429:
            return hasWaited429 ? .stop : .waitRetryAfterThenEnd(retryAfter)
        default:
            return .stop
        }
    }
}
