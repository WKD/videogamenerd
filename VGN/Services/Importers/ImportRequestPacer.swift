import Foundation

/// Enforces the minimum inter-request spacing (PLAN §14.1 rule 2 — serial, ≥ delay,
/// jittered). Before each request the client calls ``waitBeforeNextRequest()``; the
/// first call returns at once, every later call sleeps until at least `minDelay`
/// (plus `0...jitter` seconds) after the previous one. Time and randomness are
/// injected (``ServiceClock`` + an RNG closure) so tests drive it with a ``ManualClock``
/// and a fixed jitter, and no real time ever passes.
actor ImportRequestPacer {
    private let pacing: ImportPolicy.Pacing
    private let clock: ServiceClock
    /// Returns a value in `0...1`; scaled by `pacing.jitter`.
    private let jitter: @Sendable () -> Double
    private var lastRequestAt: TimeInterval?

    init(pacing: ImportPolicy.Pacing,
         clock: ServiceClock,
         jitter: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.pacing = pacing
        self.clock = clock
        self.jitter = jitter
    }

    /// Suspend until the next request is allowed, then mark "now" as that request's time.
    func waitBeforeNextRequest() async throws {
        if let last = lastRequestAt {
            let wait = pacing.minDelay + jitter() * pacing.jitter
            let deadline = last + wait
            if clock.now < deadline {
                try await clock.sleep(until: deadline)
            }
        }
        lastRequestAt = clock.now
    }
}
