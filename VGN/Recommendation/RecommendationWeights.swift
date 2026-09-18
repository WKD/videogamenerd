import Foundation

/// **Every tunable constant** of the Play Next engine, in one place (PLAN §7b:
/// "All weights are constants in one file"). Pure Foundation. Chosen for a
/// personal library of ~50–100 ranked games where the design is a *shortlist
/// ranker*, not a statistical learner (PLAN §7b sizing).
///
/// The blend, given a candidate:
/// ```
/// tasteScore = mean + traitAffinityWeight·affinityDeviation + directLinkScore
/// blended    = (1 − crowdWeight)·tasteScore + crowdWeight·crowdScore
/// final      = blended + timeFitWeight·(timeFit − 1) + rotationJitter − pickedPenalty
/// ```
/// where `affinityDeviation` and `directLinkScore` are centered on 0 (a neutral
/// game scores at your mean, ≈ 0.5).
struct RecommendationWeights: Sendable, Hashable {

    // MARK: Trait affinities (shrunk Bayesian average)

    /// Prior strength K for shrinking a trait's mean toward your overall mean
    /// (PLAN §7b: "prior strength ≈ 4 games"). A trait seen in ≤ K ranked games is
    /// pulled halfway-or-more to neutral, so one S-tier racing game barely moves
    /// "racing"; three souls-likes in S make "souls-like" strongly positive.
    var traitPriorStrength: Double = 4

    /// How much a candidate's confidence-weighted trait deviation moves its taste
    /// score. Deviation is in ≈ [−0.5, +0.5]; at weight 0.9 a maximally-loved trait
    /// profile lifts a candidate ~0.45 above your mean.
    var traitAffinityWeight: Double = 0.9

    // MARK: Direct links (franchise / series / developer / similar)

    /// Per-kind multipliers on a link's contribution (the linked ranked game's
    /// `score − 0.5`, i.e. signed by how high you ranked it). Franchise/series are
    /// the most legible signal at small scale; `similar` borrows IGDB's crowd
    /// "people who like X like Y"; developer is a softer signal.
    var franchiseLinkWeight: Double = 0.60
    var seriesLinkWeight: Double = 0.55
    var developerLinkWeight: Double = 0.30
    var similarLinkWeight: Double = 0.45

    /// A single candidate can accumulate several links; cap the summed direct-link
    /// contribution so links inform but never fully crown a pick.
    var directLinkCap: Double = 0.5

    /// Below this score a linked ranked game is "disliked" — a link to it subtracts
    /// (PLAN §7b: "Links to games I ranked D–F subtract"). Equal to the top of the
    /// D band on a 0…1 rank scale is handled naturally by `score − 0.5` being
    /// negative; this is only used when *labelling* a link positive vs negative.
    var dislikedScoreThreshold: Double = 0.34

    // MARK: Crowd prior (IGDB aggregated rating)

    /// Base ceiling on the crowd prior's weight in the blend.
    var crowdBaseWeight: Double = 0.7

    /// The crowd prior's weight decays as `crowdRankedHalfLife / (half-life + ranked
    /// count)` (PLAN §7b: "dominant with 10 ranked games, a tie-breaker with 200").
    /// At half-life = 10, ten ranked games ⇒ 0.5 of the base, 200 ⇒ ~0.05.
    var crowdRankedHalfLife: Double = 10

    /// Rating-count confidence: `count / (count + this)`. A handful of ratings
    /// count for little; hundreds count nearly fully.
    var crowdCountConfidence: Double = 25

    // MARK: Time fit

    /// Multiplier on the upper bound past which a candidate is hard-excluded
    /// (PLAN §7b: "hard exclusion beyond ~1.5× the upper bound").
    var timeHardMultiplier: Double = 1.5

    /// The floor a much-too-short game falls to for a bracket that wants long games
    /// (still eligible, just a weaker fit).
    var timeShortFloor: Double = 0.55

    /// How much the (0…1) time fit nudges the final score. Time is mainly a filter;
    /// this only breaks ties toward games squarely inside the bracket.
    var timeFitWeight: Double = 0.06

    // MARK: Rotation / feedback

    /// Amplitude of the deterministic per-game freshness jitter (PLAN §7b: `R`
    /// re-rolls among near-ties). Only games within ≈ 2× of this in score can swap
    /// on a re-roll, so a clear winner is stable.
    var rotationMagnitude: Double = 0.03

    /// A small penalty for a game already logged as `picked`, so the pitch rotates.
    var pickedPenalty: Double = 0.04

    /// How long a "Not this one" snooze lasts (PLAN §7b: "a few weeks"). The store
    /// derives snoozed-until from the feedback timestamp + this window.
    var snoozeWindow: TimeInterval = 21 * 24 * 3600

    // MARK: Match strength

    /// Evidence mass = Σ trait confidences + Σ |link contributions|. Thresholds,
    /// combined with the ranked-count gates below.
    var strongEvidence: Double = 1.6
    var fairEvidence: Double = 0.6
    /// Below this many ranked games the match can never be "strong"…
    var strongMinRanked: Int = 25
    /// …and below this many it can never be better than "weak" (PLAN §7b: under
    /// ~15 ranked games the model is thin; 5 ranked ⇒ weak).
    var fairMinRanked: Int = 8

    init() {}
}
