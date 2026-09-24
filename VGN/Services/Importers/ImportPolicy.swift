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

    /// **The Vault's one gate: 10 minutes of play** (PLAN §16, owner 2026-09-20). A source
    /// entry becomes a library game only when it was played **strictly more than** this many
    /// seconds (or is a Batocera favourite / a hand promotion). Shared by both importers:
    /// Batocera's promotion threshold (this *raises* its earlier 5-minute rule) and PSN's PS
    /// Plus-claim gate (a `PS_PLUS` entitlement played ≤ this goes to the Vault, not the
    /// library or the Ignored bucket). One place, "a code review, not a setting".
    static let vaultPlaytimeGateSeconds = 600

    /// GOG: ≥ 1 s between requests, budget 15 (PLAN §14.1 rule 2 — a 300-game
    /// library needs 1 + 1 + 3 = 5).
    static let gog = Pacing(minDelay: 1.0, jitter: 0.5, budget: 15)

    /// PSN: ≥ 1.5 s between requests, budget 40 (PLAN §13.1 rule 3). Not wired yet —
    /// here so the PSN lane reuses the same file.
    static let psn = Pacing(minDelay: 1.5, jitter: 0.5, budget: 40)

    // MARK: - HowLongToBeat (PLAN §5.3)

    /// HLTB fallback fetch: serial, ≥ 1.5 s (jittered) between requests, budget 250
    /// per run (a whole-library gap-fill of ~150 games plus discovery, well under a
    /// hard cap). The site has no account at stake, but the same machinery applies
    /// (allow-list, pacer, budget, validator, stop-on-first-unexpected-response).
    static let hltb = Pacing(minDelay: 1.5, jitter: 0.5, budget: 250)

    /// A found HLTB match is cached 180 days (PLAN §5.3 — hits are stable), a
    /// "no result" 30 days (retry sooner in case the title later appears). A cached
    /// answer, hit or miss, costs zero requests.
    static let hltbHitTTL: TimeInterval = 180 * 24 * 60 * 60
    static let hltbMissTTL: TimeInterval = 30 * 24 * 60 * 60

    /// There is deliberately **no** "refresh floor" (wave 21, D3): an explicit Refresh
    /// serves any valid cached reply inside these TTLs, exactly like Fetch Missing — a
    /// Refresh re-applies VGN's mapping + matching, and HLTB's community numbers move
    /// slowly. "Ask HowLongToBeat Again" (`HLTBFreshnessPolicy.bypassOne`) is the one
    /// explicit per-game bypass.
}
