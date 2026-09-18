import Foundation

/// Backoff policy for `withRetry`. Exponential with a cap, multiplied by a jitter
/// factor drawn from `jitter`.
struct RetryPolicy: Sendable {
    var maxAttempts: Int
    var baseDelay: TimeInterval
    var maxDelay: TimeInterval
    /// Multiplier range applied to each computed delay (full jitter lives here).
    var jitter: ClosedRange<Double>

    init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 8,
        jitter: ClosedRange<Double> = 0.7...1.3
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// A policy that never retries (single attempt) — handy in tests.
    static let none = RetryPolicy(maxAttempts: 1)
}

/// Decides whether a thrown error is worth retrying. Retries on server rate-limit /
/// 5xx (`HTTPStatusError.isRetryable`) and on transient `URLError`s. Everything else
/// — including `CancellationError` — propagates immediately.
func isRetryable(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let status = error as? HTTPStatusError { return status.isRetryable }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
    return false
}

/// Run `operation`, retrying retryable failures with jittered exponential backoff.
/// Honours a server `Retry-After` when present. Cancellation-safe: a cancelled sleep
/// or a `CancellationError` from `operation` aborts without further retries.
///
/// - Parameters:
///   - jitterProvider: returns a value in 0...1; injected so tests are deterministic.
func withRetry<T: Sendable>(
    policy: RetryPolicy = RetryPolicy(),
    clock: ServiceClock = SystemClock(),
    jitterProvider: @Sendable () -> Double = { Double.random(in: 0...1) },
    operation: sending () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        try Task.checkCancellation()
        do {
            return try await operation()
        } catch {
            attempt += 1
            if attempt >= policy.maxAttempts || !isRetryable(error) {
                throw error
            }
            let delay = backoffDelay(
                attempt: attempt,
                policy: policy,
                serverHint: (error as? HTTPStatusError)?.retryAfter,
                jitterProvider: jitterProvider
            )
            try await clock.sleep(for: delay)
        }
    }
}

/// Compute the delay before retry `attempt` (1-based). A server `Retry-After` hint,
/// when given, wins over the computed backoff (still capped by `maxDelay`).
func backoffDelay(
    attempt: Int,
    policy: RetryPolicy,
    serverHint: TimeInterval?,
    jitterProvider: @Sendable () -> Double
) -> TimeInterval {
    if let hint = serverHint {
        return min(hint, policy.maxDelay)
    }
    let exponential = policy.baseDelay * pow(2.0, Double(attempt - 1))
    let capped = min(exponential, policy.maxDelay)
    let lower = policy.jitter.lowerBound
    let upper = policy.jitter.upperBound
    let factor = lower + (upper - lower) * min(max(jitterProvider(), 0), 1)
    return capped * factor
}
