import Foundation

/// Scores **Batocera ROM catalogue** entries by the owner's taste for the "Discover on your
/// Batocera" row (PLAN §15), reusing the exact pure taste machinery Play Next uses —
/// ``TraitProfile`` (traits weighted by the owner's tiers / derived scores) and
/// ``DirectLinks`` ("same series as X", "from the makers of Y") — without touching the
/// engine, its ``RecommendationWeights`` or the backtest.
///
/// It differs from ``RecommendationEngine`` in three deliberate ways, all from PLAN §15:
///  - **No time term.** A catalogue entry rarely has a knowable length, so time fit is
///    neutral (never a penalty), and the whole term is dropped.
///  - **Crowd rating is only a prior.** ScreenScraper gives a 0…1 rating but no rating
///    *count*, so the engine's count-confidence crowd weight would be zero. Instead a small,
///    capped crowd weight (shrinking as the owner ranks more games) blends the rating in.
///  - **System affinity.** A small constant nudge for systems the owner actually plays.
///  - **Weekly rotation.** A deterministic per-(week, entry) jitter mixes exploration into
///    the top so the row changes week to week without being random on every refresh; a
///    "Shuffle" re-roll perturbs the seed within the week.
enum DiscoverScorer {

    /// One scored catalogue entry: the entry, its 0…1 blended score, the structured reasons
    /// (turned into sentences by ``PlayNextReasonFormatter``), and the match strength badge.
    struct Scored: Sendable, Equatable {
        var entry: RomCatalogEntry
        var score: Double
        var reasons: [PlayNextReason]
        var strength: MatchStrength
    }

    /// Tunables for a Discover run. `weights` is the shared read-only engine weights; the two
    /// small constants are local to Discover (the engine has no catalogue-specific terms).
    struct Options: Sendable {
        /// The ISO-week rotation seed (mixed with a "Shuffle" counter).
        var seed: UInt64 = 0
        /// Systems the owner has real play time on (a small, constant affinity nudge).
        var playedSystems: Set<String> = []
        var weights = RecommendationWeights()
        /// The crowd prior's maximum blend weight (it only ever nudges near-ties).
        var crowdWeightCap = 0.25
        /// The constant score nudge for a system the owner actually plays.
        var systemAffinityBonus = 0.03

        init(seed: UInt64 = 0, playedSystems: Set<String> = [],
             weights: RecommendationWeights = RecommendationWeights(),
             crowdWeightCap: Double = 0.25, systemAffinityBonus: Double = 0.03) {
            self.seed = seed
            self.playedSystems = playedSystems
            self.weights = weights
            self.crowdWeightCap = crowdWeightCap
            self.systemAffinityBonus = systemAffinityBonus
        }
    }

    /// Score every entry (never-played pool), best first. Pure; deterministic for a given
    /// `seed`. Builds the taste profile + link index once.
    static func score(entries: [RomCatalogEntry], ranked: [RankedGame],
                      options: Options = Options()) -> [Scored] {
        guard !entries.isEmpty else { return [] }
        let weights = options.weights
        let profile = TraitProfile(ranked: ranked, weights: weights)
        let index = DirectLinks.Index(ranked: ranked)
        let rankedCount = ranked.count

        let scored = entries.compactMap { entry -> Scored? in
            // "Not Interested" / promoted rows never return (the pool query already excludes
            // them; this is a defensive belt).
            guard !entry.notInterested, entry.promotedGameID == nil else { return nil }
            return scoreOne(entry, profile: profile, index: index,
                            rankedCount: rankedCount, options: options)
        }
        return scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.entry.id < b.entry.id
        }
    }

    private static func scoreOne(_ entry: RomCatalogEntry, profile: TraitProfile,
                                 index: DirectLinks.Index, rankedCount: Int,
                                 options: Options) -> Scored {
        let weights = options.weights
        let traits = entry.traits
        let affinity = profile.affinity(for: traits)

        // DirectLinks wants a Candidate; a catalogue entry has no IGDB id and no `.similar`
        // trait, so only franchise/developer value links fire. A negative id keeps it from
        // colliding with any real ranked game id in the index's similar-link dedupe.
        let pseudo = Candidate(id: -(entry.id + 1), igdbID: nil, traits: traits, status: .backlog)
        let linkResult = DirectLinks.evaluate(candidate: pseudo, index: index, weights: weights)

        let tasteSignal = weights.traitAffinityWeight * affinity.deviation + linkResult.score
        let tasteScore = clamp(profile.mean + tasteSignal)

        // Crowd rating as a prior only (ScreenScraper 0…1 → CrowdPrior's 0…100 scale). The
        // weight shrinks as the owner ranks more games, and is capped well below the taste
        // terms so it never drives the row.
        var blended = tasteScore
        if let rating = entry.rating,
           let crowdScore = CrowdPrior.score(rating: rating * 100) {
            let decay = weights.crowdRankedHalfLife / (weights.crowdRankedHalfLife + Double(rankedCount))
            let crowdWeight = min(options.crowdWeightCap, weights.crowdBaseWeight * decay)
            blended = (1 - crowdWeight) * tasteScore + crowdWeight * crowdScore
        }

        // System affinity + weekly rotation jitter.
        let systemBonus = options.playedSystems.contains(entry.system) ? options.systemAffinityBonus : 0
        let jitter = RecommendationEngine.rotationJitter(
            seed: options.seed, id: entry.id, magnitude: weights.rotationMagnitude)
        let finalScore = clamp(blended + systemBonus + jitter)

        let evidenceMass = affinity.evidence + linkResult.links.map { abs($0.contribution) }.reduce(0, +)
        let strength = matchStrength(evidenceMass: evidenceMass, rankedCount: rankedCount, weights: weights)
        let reasons = buildReasons(entry: entry, affinity: affinity, links: linkResult.links,
                                   crowdRating: entry.rating, strength: strength, weights: weights)
        return Scored(entry: entry, score: finalScore, reasons: reasons, strength: strength)
    }

    private static func matchStrength(evidenceMass: Double, rankedCount: Int,
                                      weights: RecommendationWeights) -> MatchStrength {
        if evidenceMass >= weights.strongEvidence && rankedCount >= weights.strongMinRanked { return .strong }
        if evidenceMass >= weights.fairEvidence && rankedCount >= weights.fairMinRanked { return .fair }
        return .weak
    }

    /// Reasons mirror ``RecommendationEngine`` (direct links, positive trait affinities, the
    /// crowd prior) minus the time / subscription tails that do not apply to a ROM.
    private static func buildReasons(
        entry: RomCatalogEntry,
        affinity: (deviation: Double, evidence: Double, contributions: [TraitProfile.Contribution]),
        links: [DirectLinks.Link],
        crowdRating: Double?,
        strength: MatchStrength,
        weights: RecommendationWeights
    ) -> [PlayNextReason] {
        var drivers: [(magnitude: Double, reason: PlayNextReason)] = []

        for link in links where link.contribution > 0 {
            let reason: PlayNextReason
            switch link.kind {
            case .franchise: reason = .sharedFranchise(value: link.value, with: link.exemplar)
            case .series: reason = .sharedSeries(value: link.value, with: link.exemplar)
            case .developer: reason = .sameDeveloper(name: link.value, exemplar: link.exemplar)
            case .similar: reason = .similarTo(link.exemplar)
            default: continue
            }
            drivers.append((abs(link.contribution), reason))
        }

        for c in affinity.contributions where c.lift > 0 && c.key.kind != .similar {
            drivers.append((abs(c.weighted) * weights.traitAffinityWeight,
                            .traitAffinity(kind: c.key.kind, value: c.key.value, lift: c.lift)))
        }

        drivers.sort { $0.magnitude > $1.magnitude }
        var reasons = drivers.prefix(3).map(\.reason)

        // The crowd rating as a soft tail (ScreenScraper 0…1 → a 0…100 figure the formatter
        // renders); only when the crowd likes it and it did not already earn taste drivers.
        if reasons.isEmpty, let rating = crowdRating, rating >= 0.7 {
            reasons.append(.crowdRated(rating: rating * 100, count: nil))
        }
        if strength == .weak { reasons.append(.weakEvidence) }
        return reasons
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
