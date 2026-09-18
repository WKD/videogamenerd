import Foundation

/// Token-bucket rate limiter (PLAN §5.1: IGDB is 4 req/s). Also reused by the cover
/// providers to stay polite toward GitHub's unauthenticated API.
///
/// Design: a fractional token bucket that is allowed to go negative — a caller that
/// arrives with no tokens left "borrows from the future" and is told the exact
/// deadline at which its token will have refilled. Reservation (`reserve`) runs with
/// no `await` inside, so concurrent callers are serialised by actor isolation and
/// each gets a distinct, ordered deadline; the actual wait happens off-actor on the
/// injected clock, so it is cancellable and instant under a manual test clock.
actor RateLimiter {
    private let capacity: Double        // burst size, in tokens
    private let refillInterval: Double  // seconds to regain one token = 1 / rate
    private let clock: ServiceClock

    private var tokens: Double
    private var lastRefill: TimeInterval

    /// - Parameters:
    ///   - rate: sustained requests per second.
    ///   - burst: how many requests may fire back-to-back after an idle period
    ///     (defaults to `rate`, i.e. one second of budget).
    init(rate: Double, burst: Double? = nil, clock: ServiceClock = SystemClock()) {
        precondition(rate > 0, "rate must be positive")
        self.capacity = max(1, burst ?? rate)
        self.refillInterval = 1.0 / rate
        self.clock = clock
        self.tokens = capacity
        self.lastRefill = clock.now
    }

    /// Acquire one token, waiting (cancellably) until the bucket permits it.
    func acquire() async throws {
        let deadline = reserve()
        try await clock.sleep(until: deadline)
    }

    /// Run `body` once a token is available. Convenience wrapper around `acquire()`.
    func run<T: Sendable>(_ body: sending () async throws -> T) async throws -> T {
        try await acquire()
        return try await body()
    }

    /// Synchronously consume a token and return the earliest time the caller may
    /// proceed. Contains no `await`, so it is atomic under actor isolation.
    private func reserve() -> TimeInterval {
        let current = clock.now
        // Refill for elapsed time, capped at capacity on the positive side.
        let refilled = tokens + (current - lastRefill) / refillInterval
        tokens = min(capacity, refilled)
        lastRefill = current

        tokens -= 1
        if tokens >= 0 {
            return current
        }
        // Bucket is in deficit: wait for the borrowed token to refill.
        return current + (-tokens) * refillInterval
    }
}
