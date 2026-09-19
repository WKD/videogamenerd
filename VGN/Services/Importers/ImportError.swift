import Foundation

/// The typed failures a sync surfaces (PLAN §14.5 — a sync stops, it never quietly
/// continues). `rejected` carries the redacted diagnostics the stop-and-ask message
/// is built from; `budgetExceeded` and `disallowedURL` are programming/limit guards.
enum ImportError: Error, Sendable, Equatable {
    /// No valid session/token — the caller must sign in (PLAN §14.1 rule 4, 401 path).
    case notAuthenticated
    /// A URL outside the compiled allow-list was about to be requested. A bug — traps
    /// in DEBUG (PLAN §14.1 rule 1).
    case disallowedURL(String)
    /// The per-sync request budget was reached; the sync aborts (PLAN §14.1 rule 2).
    case budgetExceeded(limit: Int)
    /// A response was bogus: stop, record, surface (PLAN §14.2 / §14.5). Carries the
    /// already-redacted diagnostics.
    case rejected(ImportReject)
}
