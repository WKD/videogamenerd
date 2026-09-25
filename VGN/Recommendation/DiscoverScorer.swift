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
///  - **Pinned favourites.** A never-played ★ favourite still in the catalogue (no confident
///    match, auto-add off, or over the batch cap) is pinned at the head of the row, ordered
///    among the favourites by taste score, exempt from the weekly rotation jitter, and given
///    the reason "★ your favourite" first — but at most half the visible cards may be pinned,
///    so the row still discovers (PLAN §15).
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
        /// How many never-played favourites may be pinned at the head of the row (PLAN §15 —
        /// "at most half of the visible cards"). The model passes `cardCount / 2`; the pure
        /// default is unbounded so non-UI callers see every favourite pinned.
        var maxPinnedFavourites = Int.max

        // MARK: The Vault — PS Plus terms (PLAN §16)

        /// The chosen time bracket. When set, an entry with a known IGDB length (a matched PS
        /// Plus entry) gets a time-fit term; a ROM has no length, so its time stays neutral.
        var bracket: TimeBracket?
        /// The owner's play style, for the personal length behind the time-fit + finishability.
        var playStyle: PlayStyle = .default
        /// The owner's personal pace factor (PLAN §7b "Scheduled 2026-09-25") — multiplies the
        /// personal length behind the Vault time fit + finishability. 1.0 = advertised times.
        /// Per genre: an entry resolves its factor from its IGDB genre traits (PLAN §7b).
        var paceFactor: PaceProfile = .neutral
        /// The owner's weekly pace, for the deadline finishability (§15).
        var pace: PlayPace = .default
        /// Months until the owner plans to leave PS Plus (nil ⇒ no date; the constant fallback
        /// applies instead). Feeds ``PSPlusDeadlineBoost``.
        var psPlusMonthsLeft: Double?
        /// Prioritise PS Plus games with the small constant boost when no date is set (PLAN §16
        /// — "Prioritise PS Plus games", on by default).
        var prioritisePSPlus = true

        init(seed: UInt64 = 0, playedSystems: Set<String> = [],
             weights: RecommendationWeights = RecommendationWeights(),
             crowdWeightCap: Double = 0.25, systemAffinityBonus: Double = 0.03,
             maxPinnedFavourites: Int = Int.max,
             bracket: TimeBracket? = nil, playStyle: PlayStyle = .default,
             pace: PlayPace = .default, psPlusMonthsLeft: Double? = nil,
             prioritisePSPlus: Bool = true, paceFactor: PaceProfile = .neutral) {
            self.seed = seed
            self.playedSystems = playedSystems
            self.weights = weights
            self.crowdWeightCap = crowdWeightCap
            self.systemAffinityBonus = systemAffinityBonus
            self.maxPinnedFavourites = maxPinnedFavourites
            self.bracket = bracket
            self.playStyle = playStyle
            self.pace = pace
            self.psPlusMonthsLeft = psPlusMonthsLeft
            self.prioritisePSPlus = prioritisePSPlus
            self.paceFactor = paceFactor
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
            // "Not Interested" / promoted / unmatched-PS-Plus rows never return (the pool query
            // already excludes them; this is a defensive belt).
            guard !entry.notInterested, entry.promotedGameID == nil, entry.isSuggestable else { return nil }
            return scoreOne(entry, profile: profile, index: index,
                            rankedCount: rankedCount, options: options)
        }
        let ordered = scored.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.entry.id < b.entry.id
        }
        // Pin never-played favourites at the head, capped so the row still discovers. They are
        // already jitter-free (scoreOne exempts favourites from the weekly rotation), so their
        // order among themselves is the taste order (PLAN §15).
        guard options.maxPinnedFavourites > 0 else { return ordered }
        var pinned: [Scored] = []
        var rest: [Scored] = []
        for s in ordered {
            if s.entry.isFavorite && pinned.count < options.maxPinnedFavourites {
                pinned.append(s)
            } else {
                rest.append(s)
            }
        }
        return pinned + rest
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

        // Crowd rating as a prior only (ScreenScraper 0…1 or IGDB 0…100 → CrowdPrior's 0…100
        // scale). The weight shrinks as the owner ranks more games, and is capped well below the
        // taste terms so it never drives the row.
        var blended = tasteScore
        if let crowd100 = entry.crowdRating0to100,
           let crowdScore = CrowdPrior.score(rating: crowd100) {
            let decay = weights.crowdRankedHalfLife / (weights.crowdRankedHalfLife + Double(rankedCount))
            let crowdWeight = min(options.crowdWeightCap, weights.crowdBaseWeight * decay)
            blended = (1 - crowdWeight) * tasteScore + crowdWeight * crowdScore
        }

        // Time fit — only when a length is known (matched PS Plus entries usually have IGDB
        // times; ROMs do not, so the term is neutral, never a penalty). PLAN §16.
        // Ignore a suspicious (out-of-scale) completionist for the Vault time fit too
        // (PLAN §5.3, D5). Vault entries carry no rushed time / source / dismissal, so only
        // the completionist side can ever be rewritten (`completionist ≥ 4× main`).
        let vaultLength = EstimateSanity.lengthInputs(
            rushed: nil, main: entry.lengthMainSeconds, completionist: entry.lengthCompleteSeconds,
            sourceIsHLTB: false, dismissed: false)
        let personal = PersonalLength.compute(
            normallyS: vaultLength.main, completelyS: vaultLength.completionist, style: options.playStyle,
            paceFactor: options.paceFactor.factor(traits: traits))
        var timeTerm = 0.0
        var timeFit: TimeFit.Result?
        if let bracket = options.bracket, let personal {
            let fit = TimeFit.evaluate(estimateSeconds: personal.seconds, bracket: bracket, weights: weights)
            timeFit = fit
            timeTerm = weights.timeFitWeight * (fit.fit - 1)
        }

        // PS Plus deadline ramp / constant fallback (PLAN §16) — only for PS Plus subscription
        // entries (a hand-vaulted *owned* purchase never gets it).
        var subBonus = 0.0
        let isPSPlus = entry.isPSPlusSubscription
        if isPSPlus {
            if options.psPlusMonthsLeft != nil {
                subBonus = PSPlusDeadlineBoost.boost(monthsLeft: options.psPlusMonthsLeft,
                                                     personalLengthSeconds: personal?.seconds,
                                                     pace: options.pace)
            } else if options.prioritisePSPlus {
                subBonus = weights.subscriptionBonus
            }
        }

        // System affinity + weekly rotation jitter. A ★ favourite is a deliberate pick, so it
        // is exempt from the rotation jitter (PLAN §15) — its order is pure taste.
        let systemBonus = options.playedSystems.contains(entry.system) ? options.systemAffinityBonus : 0
        let jitter = entry.isFavorite ? 0 : RecommendationEngine.rotationJitter(
            seed: options.seed, id: entry.id, magnitude: weights.rotationMagnitude)
        let finalScore = clamp(blended + timeTerm + systemBonus + subBonus + jitter)

        let evidenceMass = affinity.evidence + linkResult.links.map { abs($0.contribution) }.reduce(0, +)
        let strength = matchStrength(evidenceMass: evidenceMass, rankedCount: rankedCount, weights: weights)
        var reasons = buildReasons(entry: entry, affinity: affinity, links: linkResult.links,
                                   crowdRating: entry.crowdRating0to100, strength: strength, weights: weights)
        // Time reason (matched PS Plus entries with a length).
        if timeFit != nil, let bracket = options.bracket, let personal {
            reasons.append(.fitsBracket(estimateSeconds: personal.seconds, bracket: bracket))
        }
        // PS Plus tail: the deadline reason (with a date) or the plain "leaves with PS Plus".
        if isPSPlus {
            if let months = options.psPlusMonthsLeft, months > 0 {
                reasons.append(.leavesWithSubscriptionDeadline(
                    monthsLeft: max(1, Int(months.rounded())),
                    personalLengthSeconds: personal?.seconds))
            } else {
                reasons.append(.leavesWithSubscription)
            }
        }
        // A favourite leads with "★ your favourite", then its taste reasons (PLAN §15).
        if entry.isFavorite { reasons.insert(.batoceraFavouritePinned, at: 0) }
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

        // The crowd rating as a soft tail (already on the 0…100 scale the formatter renders);
        // only when the crowd likes it and it did not already earn taste drivers.
        if reasons.isEmpty, let rating = crowdRating, rating >= 70 {
            reasons.append(.crowdRated(rating: rating, count: nil))
        }
        if strength == .weak { reasons.append(.weakEvidence) }
        return reasons
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
