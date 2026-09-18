import Foundation

/// A minimal monotonic clock the rate limiter and retry helper depend on, so tests
/// can drive time by hand and never actually sleep. `now` is seconds on an arbitrary
/// monotonic epoch (never wall-clock, so it is immune to clock changes).
protocol ServiceClock: Sendable {
    var now: TimeInterval { get }
    /// Suspends until `deadline` (in `now`'s timebase). Returns immediately if the
    /// deadline has already passed. Must throw `CancellationError` when the task is
    /// cancelled while waiting.
    func sleep(until deadline: TimeInterval) async throws
}

extension ServiceClock {
    /// Suspends for `duration` seconds.
    func sleep(for duration: TimeInterval) async throws {
        try await sleep(until: now + duration)
    }
}

/// Production clock: monotonic time from `DispatchTime`, real `Task.sleep`.
struct SystemClock: ServiceClock {
    var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func sleep(until deadline: TimeInterval) async throws {
        let delta = deadline - now
        guard delta > 0 else {
            // Still honour cancellation on a past deadline.
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(delta * 1_000_000_000))
    }
}
