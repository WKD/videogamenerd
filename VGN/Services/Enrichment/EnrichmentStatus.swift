import Foundation

/// What the enrichment worker is doing right now, for the UI to observe
/// (PLAN §9). Delivered as an `AsyncStream<EnrichmentStatus>` by
/// ``EnrichmentCoordinator``.
enum EnrichmentStatus: Sendable, Equatable {
    /// Nothing to do — the queue is drained.
    case idle
    /// Actively fetching; `remaining` is the pending + running job count
    /// ("Fetching metadata · 12 left").
    case running(remaining: Int)
    /// Paused by the app (e.g. user toggled enrichment off).
    case paused
    /// No IGDB credentials yet — idle quietly until they appear.
    case needsCredentials
    /// Backed off after network/5xx errors; `retryAt` is when the soonest job
    /// becomes due again (nil if unknown).
    case offline(retryAt: Date?)
}
