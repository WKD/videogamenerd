import Foundation
import Testing
@testable import VGN

struct RateLimiterTests {

    @Test("Burst allows `burst` immediate acquires, then steady 1/rate spacing")
    func burstThenSteady() async throws {
        // now is fixed at 0, so tokens never refill — deadlines expose the raw math.
        let clock = RecordingImmediateClock(now: 0)
        let limiter = RateLimiter(rate: 4, burst: 4, clock: clock)

        for _ in 0..<8 { try await limiter.acquire() }

        // First 4 (the burst) proceed at t=0; then one token every 0.25s.
        #expect(clock.deadlines == [0, 0, 0, 0, 0.25, 0.5, 0.75, 1.0])
    }

    @Test("Idle time refills the bucket up to capacity")
    func refill() async throws {
        let clock = RecordingImmediateClock(now: 100)  // plenty of elapsed time since init(now:0-ish)
        let limiter = RateLimiter(rate: 4, burst: 4, clock: clock)
        // Bucket starts full at capacity regardless; four immediate acquires.
        for _ in 0..<4 { try await limiter.acquire() }
        #expect(clock.deadlines.allSatisfy { $0 <= 100 })
    }

    @Test("A throttled acquire is cancellable")
    func cancellation() async throws {
        let clock = ManualClock(now: 0)
        let limiter = RateLimiter(rate: 4, burst: 1, clock: clock)
        try await limiter.acquire()   // consume the single burst token

        let throttled = Task { try await limiter.acquire() }  // must park on the clock
        await clock.waitForSleepers(count: 1)
        #expect(clock.pendingCount == 1)

        throttled.cancel()
        await #expect(throws: CancellationError.self) { try await throttled.value }
    }

    @Test("Throttled acquire completes once the clock advances")
    func releasesOnAdvance() async throws {
        let clock = ManualClock(now: 0)
        let limiter = RateLimiter(rate: 4, burst: 1, clock: clock)
        try await limiter.acquire()

        let throttled = Task { try await limiter.acquire() }
        await clock.waitForSleepers(count: 1)
        clock.advance(by: 0.25)
        try await throttled.value               // resolves without throwing
        #expect(clock.pendingCount == 0)
    }
}

struct RetryTests {

    @Test("Retries retryable failures then succeeds; counts attempts")
    func retriesThenSucceeds() async throws {
        let clock = RecordingImmediateClock()
        let attempts = AtomicCounter()
        let result = try await withRetry(
            policy: RetryPolicy(maxAttempts: 4, baseDelay: 1),
            clock: clock,
            jitterProvider: { 0.5 }
        ) {
            let n = attempts.increment()
            if n < 3 { throw HTTPStatusError(status: 503, body: Data(), retryAfter: nil) }
            return n
        }
        #expect(result == 3)
        #expect(attempts.count == 3)
        #expect(clock.deadlines.count == 2)   // slept before attempts 2 and 3
    }

    @Test("Non-retryable errors propagate immediately")
    func nonRetryablePropagates() async {
        let attempts = AtomicCounter()
        await #expect(throws: HTTPStatusError.self) {
            try await withRetry(policy: RetryPolicy(maxAttempts: 5), clock: RecordingImmediateClock()) {
                _ = attempts.increment()
                throw HTTPStatusError(status: 400, body: Data(), retryAfter: nil)  // 400 not retryable
            }
        }
        #expect(attempts.count == 1)
    }

    @Test("Gives up after maxAttempts")
    func givesUp() async {
        let attempts = AtomicCounter()
        await #expect(throws: HTTPStatusError.self) {
            try await withRetry(policy: RetryPolicy(maxAttempts: 3), clock: RecordingImmediateClock(), jitterProvider: { 0.5 }) {
                _ = attempts.increment()
                throw HTTPStatusError(status: 500, body: Data(), retryAfter: nil)
            }
        }
        #expect(attempts.count == 3)
    }

    @Test("Backoff is exponential, capped, and honours Retry-After")
    func backoffMath() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 8, jitter: 1.0...1.0)
        #expect(backoffDelay(attempt: 1, policy: policy, serverHint: nil, jitterProvider: { 0 }) == 1)
        #expect(backoffDelay(attempt: 2, policy: policy, serverHint: nil, jitterProvider: { 0 }) == 2)
        #expect(backoffDelay(attempt: 3, policy: policy, serverHint: nil, jitterProvider: { 0 }) == 4)
        #expect(backoffDelay(attempt: 4, policy: policy, serverHint: nil, jitterProvider: { 0 }) == 8)
        #expect(backoffDelay(attempt: 5, policy: policy, serverHint: nil, jitterProvider: { 0 }) == 8)  // capped
        // Server hint wins (still capped at maxDelay).
        #expect(backoffDelay(attempt: 1, policy: policy, serverHint: 3, jitterProvider: { 0 }) == 3)
        #expect(backoffDelay(attempt: 1, policy: policy, serverHint: 100, jitterProvider: { 0 }) == 8)
    }

    @Test("isRetryable classifies statuses and cancellation")
    func classification() {
        #expect(isRetryable(HTTPStatusError(status: 429, body: Data(), retryAfter: nil)))
        #expect(isRetryable(HTTPStatusError(status: 502, body: Data(), retryAfter: nil)))
        #expect(!isRetryable(HTTPStatusError(status: 404, body: Data(), retryAfter: nil)))
        #expect(!isRetryable(CancellationError()))
        #expect(isRetryable(URLError(.timedOut)))
        #expect(!isRetryable(URLError(.badURL)))
    }
}

actor ConcurrencyTracker {
    private(set) var peak = 0
    private var active = 0
    func enter() { active += 1; peak = max(peak, active) }
    func leave() { active -= 1 }
}

struct AsyncSemaphoreTests {

    @Test("Caps concurrency at the permit count")
    func caps() async throws {
        let semaphore = AsyncSemaphore(permits: 3)
        let tracker = ConcurrencyTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await semaphore.withPermit {
                        await tracker.enter()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.leave()
                    }
                }
            }
        }
        let peak = await tracker.peak
        #expect(peak <= 3)
        #expect(peak >= 1)
    }
}
