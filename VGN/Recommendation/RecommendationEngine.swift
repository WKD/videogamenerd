import Foundation

/// The Play Next recommendation engine (PLAN §7b). Pure, deterministic, Foundation
/// only: same inputs ⇒ same pick, no I/O, milliseconds. It filters candidates by
/// time, scores the shortlist for taste (shrunk trait affinities + direct links +
/// crowd prior), rotates, and explains — returning a ``PlayNextResult``.
enum RecommendationEngine {

    /// Compute the recommendation for one bracket.
    static func recommend(_ input: RecommendationInput) -> PlayNextResult {
        let weights = input.weights
        let options = input.options
        let bracket = input.bracket
        let profile = TraitProfile(ranked: input.ranked, weights: weights)
        let linkIndex = DirectLinks.Index(ranked: input.ranked)
        let rankedCount = input.ranked.count

        var exclusions = RecommendationExclusions()
        var scored: [Scored] = []
        var unknown: [Scored] = []

        for candidate in input.candidates {
            // Status rules (PLAN §7b Candidates).
            switch candidate.status {
            case .backlog, .playing, .toRevisit:
                // `toRevisit` is a candidate by default — no "include abandoned" opt-in:
                // wanting to come back to it is the whole point of the flag (PLAN §7b).
                break
            case .abandoned:
                if !options.includeAbandoned { exclusions.byStatus += 1; continue }
            case .playedUnknown:
                if !options.includePlayedWithoutStatus { exclusions.byStatus += 1; continue }
            case .finished:
                // Never a regular pick — finished games only reach "Play it again" (wave 22).
                continue
            }

            // "Holds up today?" (PLAN §7b): a game the owner finds Too Archaic to play now is
            // not a regular pick — counted, and back only when "Include archaic" is on.
            if candidate.holdsUp == .tooArchaic && !options.includeArchaic {
                exclusions.tooArchaic += 1; continue
            }

            // Feedback (PLAN §7b rotation).
            if input.feedback.never.contains(candidate.id) { exclusions.byFeedback += 1; continue }
            if let until = input.feedback.snoozedUntil[candidate.id], options.now < until {
                exclusions.byFeedback += 1; continue
            }

            let style = bracket.resolvedStyle
            let fullEstimate = candidate.fullEstimate(style: style, paceFactor: bracket.paceFactor)
            let bracketEstimate = candidate.bracketEstimate(style: style, paceFactor: bracket.paceFactor)

            guard let estimate = bracketEstimate else {
                // No estimate → unknown-length lane (PLAN §7b).
                exclusions.unknownLength += 1
                unknown.append(score(candidate, profile: profile, index: linkIndex,
                                     rankedCount: rankedCount, bracket: bracket,
                                     timeFit: nil, fullEstimate: nil, bracketEstimate: nil,
                                     feedback: input.feedback, options: options, weights: weights))
                continue
            }

            let timeFit = TimeFit.evaluate(estimateSeconds: estimate, bracket: bracket, weights: weights)
            if timeFit.excluded { exclusions.byTime += 1; continue }

            scored.append(score(candidate, profile: profile, index: linkIndex,
                                rankedCount: rankedCount, bracket: bracket,
                                timeFit: timeFit, fullEstimate: fullEstimate, bracketEstimate: estimate,
                                feedback: input.feedback, options: options, weights: weights))
        }

        scored.sort(by: Self.rank)
        unknown.sort(by: Self.rank)

        // "Finish what you started" + "Play it again" (PLAN §7b, wave 22) — their own rows. A
        // game in the finish row is never repeated in the regular picks (replay games are
        // finished, so never regular candidates in the first place).
        let rows = extraRows(input, profile: profile, index: linkIndex, regular: scored)
        let finishIDs = Set(rows.finish.map(\.id))
        if !finishIDs.isEmpty {
            scored.removeAll { finishIDs.contains($0.id) }
            unknown.removeAll { finishIDs.contains($0.id) }
        }

        let hero = scored.first?.suggestion
        let alternatives = scored.dropFirst().prefix(options.maxAlternatives).map(\.suggestion)
        let unknownLane = unknown.prefix(options.maxUnknownLength).map(\.suggestion)

        return PlayNextResult(
            hero: hero,
            alternatives: Array(alternatives),
            unknownLength: Array(unknownLane),
            exclusions: exclusions,
            bracket: bracket,
            finishWhatYouStarted: rows.finish,
            replay: rows.replay,
            replayUndatedCount: rows.replayUndated
        )
    }

    // MARK: - Scoring one candidate

    /// A scored candidate plus the final suggestion (score already baked into it).
    struct Scored {
        var id: GameID
        var finalScore: Double
        var suggestion: PlayNextSuggestion
    }

    /// Deterministic order: score desc, then id asc (rotation jitter is already in
    /// the score, so near-ties reshuffle with the seed but clear winners are stable).
    static func rank(_ a: Scored, _ b: Scored) -> Bool {
        a.finalScore != b.finalScore ? a.finalScore > b.finalScore : a.id < b.id
    }

    static func score(
        _ candidate: Candidate,
        profile: TraitProfile,
        index: DirectLinks.Index,
        rankedCount: Int,
        bracket: TimeBracket,
        timeFit: TimeFit.Result?,
        fullEstimate: Int?,
        bracketEstimate: Int?,
        feedback: RecFeedbackState,
        options: RecommendationOptions,
        weights: RecommendationWeights
    ) -> Scored {
        let affinity = profile.affinity(for: candidate.traits)
        let linkResult = DirectLinks.evaluate(candidate: candidate, index: index, weights: weights)

        let tasteSignal = weights.traitAffinityWeight * affinity.deviation + linkResult.score
        let tasteScore = clamp(profile.mean + tasteSignal)

        let crowdScore = CrowdPrior.score(rating: candidate.igdbRating)
        let crowdWeight = CrowdPrior.weight(rating: candidate.igdbRating,
                                            ratingCount: candidate.ratingCount,
                                            rankedCount: rankedCount, weights: weights)
        let blended: Double
        if let crowdScore, crowdWeight > 0 {
            blended = (1 - crowdWeight) * tasteScore + crowdWeight * crowdScore
        } else {
            blended = tasteScore
        }

        let timeTerm = timeFit.map { weights.timeFitWeight * ($0.fit - 1) } ?? 0
        let jitter = rotationJitter(seed: options.seed, id: candidate.id, magnitude: weights.rotationMagnitude)
        let pickedPenalty = feedback.picked.contains(candidate.id) ? weights.pickedPenalty : 0
        // PS Plus term (backtest-neutral — off unless the UI passes a date / the toggle):
        // with a cancellation date, the deadline ramp scaled by finishability (PLAN §16);
        // otherwise the small constant "Prioritise PS Plus games" nudge (PLAN §13.3). Both
        // stay below the trait/crowd terms, so they only reorder near-ties.
        var subBonus = 0.0
        if candidate.ownedOnlyViaSubscription {
            if options.psPlusMonthsLeft != nil {
                subBonus = PSPlusDeadlineBoost.boost(monthsLeft: options.psPlusMonthsLeft,
                                                     personalLengthSeconds: fullEstimate,
                                                     pace: options.psPlusPace)
            } else if options.preferExpiringSubscription {
                subBonus = weights.subscriptionBonus
            }
        }
        // A modest boost for an unplayed library game the owner ★ favourited on his Batocera
        // box (PLAN §15). Same shape as the PS Plus nudge — below the taste terms, only
        // reorders near-ties — and, being applied only here, is backtest-neutral.
        let favBonus = (candidate.isBatoceraFavourite && candidate.status == .backlog)
            ? weights.batoceraFavouriteBonus : 0
        // "Holds up today?" (PLAN §7b) — adjusts the CANDIDATE only; the taste profile, trait
        // affinities and direct links above never see the mark (a nostalgic S still says "I
        // love what this game does"). Applied here only, never in the backtest ⇒ neutral.
        let holdsUpTerm = holdsUpAdjustment(candidate.holdsUp, weights: weights)
        let finalScore = clamp(blended + timeTerm + jitter - pickedPenalty + subBonus + favBonus + holdsUpTerm)

        let evidenceMass = affinity.evidence + linkResult.links.map { abs($0.contribution) }.reduce(0, +)
        let strength = matchStrength(evidenceMass: evidenceMass, rankedCount: rankedCount,
                                     hasMetadata: candidate.hasMetadata, weights: weights)

        let reasons = buildReasons(
            candidate: candidate, bracket: bracket, timeFit: timeFit,
            bracketEstimate: bracketEstimate, fullEstimate: fullEstimate,
            affinity: affinity, links: linkResult.links,
            crowdScore: crowdScore, crowdWeight: crowdWeight,
            strength: strength, weights: weights, options: options
        )

        let suggestion = PlayNextSuggestion(
            id: candidate.id,
            title: candidate.title,
            year: candidate.year,
            coverFile: candidate.coverFile,
            platformIDs: candidate.platformIDs,
            formats: candidate.formats,
            status: candidate.playStatus,
            estimateSeconds: bracketEstimate,
            fullEstimateSeconds: fullEstimate,
            score: finalScore,
            matchStrength: strength,
            reasons: reasons,
            hasMetadata: candidate.hasMetadata,
            igdbID: candidate.igdbID,
            holdsUp: candidate.holdsUp,
            firstPlayedAt: candidate.firstPlayedAt
        )
        return Scored(id: candidate.id, finalScore: finalScore, suggestion: suggestion)
    }

    /// The "Holds up today?" score term: +bonus (Holds Up), −penalty (Of Its Time, and Too
    /// Archaic when it is included at all), 0 when unrated.
    static func holdsUpAdjustment(_ mark: HoldsUp?, weights: RecommendationWeights) -> Double {
        switch mark {
        case .holdsUp: return weights.holdsUpBonus
        case .ofItsTime, .tooArchaic: return -weights.ofItsTimePenalty
        case nil: return 0
        }
    }

    // MARK: - Match strength

    private static func matchStrength(
        evidenceMass: Double, rankedCount: Int, hasMetadata: Bool, weights: RecommendationWeights
    ) -> MatchStrength {
        guard hasMetadata else { return .weak }
        if evidenceMass >= weights.strongEvidence && rankedCount >= weights.strongMinRanked { return .strong }
        if evidenceMass >= weights.fairEvidence && rankedCount >= weights.fairMinRanked { return .fair }
        return .weak
    }

    // MARK: - Reasons

    private static func buildReasons(
        candidate: Candidate,
        bracket: TimeBracket,
        timeFit: TimeFit.Result?,
        bracketEstimate: Int?,
        fullEstimate: Int?,
        affinity: (deviation: Double, evidence: Double, contributions: [TraitProfile.Contribution]),
        links: [DirectLinks.Link],
        crowdScore: Double?,
        crowdWeight: Double,
        strength: MatchStrength,
        weights: RecommendationWeights,
        options: RecommendationOptions
    ) -> [PlayNextReason] {
        var drivers: [(magnitude: Double, reason: PlayNextReason)] = []

        // Direct links (positive ones cite "because you ranked X high").
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

        // Trait affinities you tend to rank high (skip similar — covered by links).
        for c in affinity.contributions where c.lift > 0 && c.key.kind != .similar {
            drivers.append((abs(c.weighted) * weights.traitAffinityWeight,
                            .traitAffinity(kind: c.key.kind, value: c.key.value, lift: c.lift)))
        }

        // Crowd prior, when it carries real weight and speaks well of the game.
        if let crowdScore, crowdWeight >= 0.1, crowdScore >= 0.6, let rating = candidate.igdbRating {
            drivers.append((crowdWeight * (crowdScore - 0.5),
                            .crowdRated(rating: rating, count: candidate.ratingCount)))
        }

        drivers.sort { $0.magnitude > $1.magnitude }
        var reasons = drivers.prefix(3).map(\.reason)

        // Time reason (always relevant when the game has an estimate). A `toRevisit` game
        // with known playtime shows the *remaining* time, exactly like a `playing` one.
        if timeFit != nil, let estimate = bracketEstimate {
            if (candidate.status == .playing || candidate.status == .toRevisit),
               candidate.myPlaytimeSeconds != nil {
                reasons.append(.remainingTime(remainingSeconds: estimate))
            } else {
                reasons.append(.fitsBracket(estimateSeconds: estimate, bracket: bracket))
            }
        }

        // The point of "To Revisit": say why it's here (PLAN §7b). A tail reason — it never
        // changes the score (no boost), it explains the pick.
        if candidate.status == .toRevisit {
            reasons.append(.wantedToRevisit)
        }

        // "Holds up today?" (PLAN §7b): say so when the owner's mark moved this pick.
        switch candidate.holdsUp {
        case .holdsUp: reasons.append(.markedHoldsUp)
        case .ofItsTime: reasons.append(.markedOfItsTime)
        case .tooArchaic: reasons.append(.markedTooArchaic)
        case nil: break
        }

        // A game that leaves with PS Plus is worth flagging (PLAN §13.3/§16) — an informative
        // tail reason. With a cancellation date set, it carries the months-left + finishability
        // detail; otherwise the plain marker.
        if candidate.ownedOnlyViaSubscription {
            if let months = options.psPlusMonthsLeft, months > 0 {
                reasons.append(.leavesWithSubscriptionDeadline(
                    monthsLeft: max(1, Int(months.rounded())), personalLengthSeconds: fullEstimate))
            } else {
                reasons.append(.leavesWithSubscription)
            }
        }
        // A ★ favourite you have not played is in the backlog because you flagged it (PLAN §15).
        if candidate.isBatoceraFavourite && candidate.status == .backlog {
            reasons.append(.batoceraFavourite)
        }

        if !candidate.hasMetadata { reasons.append(.noMetadata) }
        if strength == .weak { reasons.append(.weakEvidence) }
        return reasons
    }

    // MARK: - Deterministic rotation jitter

    /// A stable per-(seed, game) jitter in `[−magnitude, +magnitude]` (splitmix64).
    /// Re-rolling the seed reshuffles only games within ≈ 2× magnitude of each other.
    static func rotationJitter(seed: UInt64, id: GameID, magnitude: Double) -> Double {
        var x = seed &+ (UInt64(bitPattern: id) &* 0x9E37_79B9_7F4A_7C15)
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        let unit = Double(x >> 11) * (1.0 / 9_007_199_254_740_992.0)  // [0, 1)
        return (unit * 2 - 1) * magnitude
    }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}
