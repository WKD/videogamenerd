import Foundation

/// The importer knobs that PLAN §14.2 insists live in **one** place, "a code review,
/// not a setting": the 30-day cache TTL, the inter-request delay, and the per-sync
/// request budget. GOG's numbers are live; PSN's are recorded here for when §13 plugs
/// in, so both sources read the same constants file.
enum ImportPolicy {
    /// Validated responses are cached for 30 days (PLAN §14.2 / §13.2).
    static let cacheTTL: TimeInterval = 30 * 24 * 60 * 60

    /// Pacing + budget for one source's sync.
    struct Pacing: Sendable, Hashable {
        /// Minimum seconds between two requests (before jitter).
        var minDelay: TimeInterval
        /// Extra uniform jitter added on top of `minDelay`, in `0...jitter` seconds.
        var jitter: TimeInterval
        /// Hard cap on requests per sync — exceeding it aborts, never "just continues".
        var budget: Int
    }

    /// GOG: ≥ 1 s between requests, budget 15 (PLAN §14.1 rule 2 — a 300-game
    /// library needs 1 + 1 + 3 = 5).
    static let gog = Pacing(minDelay: 1.0, jitter: 0.5, budget: 15)

    /// PSN: ≥ 1.5 s between requests, budget 40 (PLAN §13.1 rule 3). Not wired yet —
    /// here so the PSN lane reuses the same file.
    static let psn = Pacing(minDelay: 1.5, jitter: 0.5, budget: 40)
}
