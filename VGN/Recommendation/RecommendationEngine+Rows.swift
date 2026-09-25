import Foundation

// MARK: - "Finish what you started" + "Play it again" (PLAN §7b "Scheduled 2026-09-25", wave 22)

/// Two extra Play Next rows, computed by the same pure engine from the same inputs:
///
/// **Finish what you started** — shown above the regular picks, never repeating them:
///  - *Almost there*: status *Playing* or *To Revisit*, effective play time ≥ 70 % of the
///    pace-adjusted personal length. Fitted on the **remaining** time (length − play time,
///    never below 30 min) against the bracket; reason "about 4 h left" — or, once past the
///    estimate, "past the estimate — maybe finish it?".
///  - *Worth another try*: status *Abandoned* (not *To Revisit*, which is already a regular
///    candidate), play time < 25 % of the length, and a **strong taste match** — its engine
///    score is in the top quartile of every candidate fitting this bracket, OR it is directly
///    linked (franchise / series / developer / similar) to a game the owner ranked S or A.
///    Fitted on the full length (a restart). Reason "you dropped it after 3 h — you loved X".
///
/// **Play it again** ▸ *Worth replaying* — finished / 100 % games marked **Holds Up**, tier
/// S or A, whose importer-filled last-played date is ≥ 3 years ago; fitted with the full
/// personal length; reason "you gave it S · last played 2019". A game without a
/// last-played date is not eligible — it is only counted for the row's footer.
///
/// Both rows exclude *Too Archaic* games (whatever "Include archaic" says), honour **Never**
/// and **Not this one** (snooze), and carry the picked-rotation penalty. Neither row feeds
/// the taste profile or the backtest (they only read ranked games, as before).
extension RecommendationEngine {

    struct ExtraRows {
        var finish: [PlayNextSuggestion] = []
        var replay: [PlayNextSuggestion] = []
        var replayUndated = 0
    }

    static func extraRows(
        _ input: RecommendationInput, profile: TraitProfile, index: DirectLinks.Index,
        regular: [Scored]
    ) -> ExtraRows {
        var rows = ExtraRows()
        rows.finish = finishRow(input, profile: profile, index: index, regular: regular)
        let replay = replayRow(input)
        rows.replay = replay.suggestions
        rows.replayUndated = replay.undated
        return rows
    }

    // MARK: Shared gates

    /// Too Archaic, Never and an active snooze keep a game out of both extra rows.
    static func passesRowGates(_ c: Candidate, feedback: RecFeedbackState, now: Double) -> Bool {
        if c.holdsUp == .tooArchaic { return false }
        if feedback.never.contains(c.id) { return false }
        if let until = feedback.snoozedUntil[c.id], now < until { return false }
        return true
    }

    // MARK: Finish what you started

    /// Which pool a candidate qualifies for, before the taste test (pure; tested directly).
    enum FinishPool: Equatable {
        /// *Almost there*: the time the bracket is fitted on, and whether play time already
        /// reached the estimate.
        case almostThere(remainingSeconds: Int, pastEstimate: Bool)
        /// *Worth another try* (subject to the strong-taste test).
        case droppedEarly(playedSeconds: Int)
    }

    /// The pool rule over one candidate's status, play time and pace-adjusted length.
    static func finishPool(_ c: Candidate, fullSeconds: Int?, weights: RecommendationWeights) -> FinishPool? {
        guard let played = c.myPlaytimeSeconds, played > 0, let full = fullSeconds, full > 0 else { return nil }
        switch c.status {
        case .playing, .toRevisit:
            guard Double(played) >= weights.almostThereFraction * Double(full) else { return nil }
            let remaining = max(full - played, weights.remainingFloorSeconds)
            return .almostThere(remainingSeconds: remaining, pastEstimate: played >= full)
        case .abandoned:
            guard Double(played) < weights.droppedEarlyFraction * Double(full) else { return nil }
            return .droppedEarly(playedSeconds: played)
        case .backlog, .playedUnknown, .finished:
            return nil
        }
    }

    /// The score a candidate must reach to be "top quartile" among `scores` (every candidate
    /// fitting the bracket). With no scores there is no threshold (nil ⇒ nothing qualifies).
    static func topQuantileThreshold(_ scores: [Double], quantile: Double) -> Double? {
        guard !scores.isEmpty else { return nil }
        let sorted = scores.sorted(by: >)
        let topCount = max(1, Int((Double(sorted.count) * (1 - quantile)).rounded(.up)))
        return sorted[min(topCount, sorted.count) - 1]
    }

    private static func finishRow(
        _ input: RecommendationInput, profile: TraitProfile, index: DirectLinks.Index,
        regular: [Scored]
    ) -> [PlayNextSuggestion] {
        let weights = input.weights
        let options = input.options
        let bracket = input.bracket
        let style = bracket.resolvedStyle
        let tierByRanked = Dictionary(input.ranked.compactMap { r in r.tierLetter.map { (r.id, $0) } },
                                      uniquingKeysWith: { a, _ in a })

        var almost: [Scored] = []
        var dropped: [(scored: Scored, played: Int, loved: GameID?)] = []

        for c in input.candidates {
            guard passesRowGates(c, feedback: input.feedback, now: options.now) else { continue }
            let full = c.fullEstimate(style: style, paceFactor: bracket.paceFactor)
            guard let pool = finishPool(c, fullSeconds: full, weights: weights) else { continue }
            switch pool {
            case let .almostThere(remaining, past):
                let fit = TimeFit.evaluate(estimateSeconds: remaining, bracket: bracket, weights: weights)
                guard !fit.excluded else { continue }
                var s = score(c, profile: profile, index: index, rankedCount: input.ranked.count,
                              bracket: bracket, timeFit: fit, fullEstimate: full, bracketEstimate: remaining,
                              feedback: input.feedback, options: options, weights: weights)
                s.suggestion.reasons = [.almostThere(remainingSeconds: remaining, pastEstimate: past)]
                    + s.suggestion.reasons.filter { !isTimeReason($0) }
                almost.append(s)
            case let .droppedEarly(played):
                guard let full else { continue }
                let fit = TimeFit.evaluate(estimateSeconds: full, bracket: bracket, weights: weights)
                guard !fit.excluded else { continue }
                let s = score(c, profile: profile, index: index, rankedCount: input.ranked.count,
                              bracket: bracket, timeFit: fit, fullEstimate: full, bracketEstimate: full,
                              feedback: input.feedback, options: options, weights: weights)
                // The strongest positive direct link to a game ranked S/A, if any.
                let links = DirectLinks.evaluate(candidate: c, index: index, weights: weights).links
                let loved = links
                    .filter { $0.contribution > 0 && weights.lovedTierLetters.contains(tierByRanked[$0.exemplar] ?? "") }
                    .max { $0.contribution < $1.contribution }?.exemplar
                dropped.append((s, played, loved))
            }
        }

        // "Top quartile of the engine's score over every candidate fitting this bracket": the
        // regular shortlist pool plus the dropped-early ones (deduplicated by id — an abandoned
        // game is also a regular candidate when "Include abandoned" is on).
        var allScores: [GameID: Double] = [:]
        for s in regular { allScores[s.id] = s.finalScore }
        for d in dropped { allScores[d.scored.id] = d.scored.finalScore }
        let threshold = topQuantileThreshold(Array(allScores.values), quantile: weights.worthAnotherTryQuantile)

        var another: [Scored] = []
        for d in dropped {
            let topQuartile = threshold.map { d.scored.finalScore >= $0 } ?? false
            guard d.loved != nil || topQuartile else { continue }
            var s = d.scored
            // Lead with the "dropped it after 3 h" sentence; a link reason citing the same loved
            // game would repeat it, so drop that one.
            s.suggestion.reasons = [.droppedEarly(playedSeconds: d.played, lovedExemplar: d.loved)]
                + s.suggestion.reasons.filter { !cites($0, d.loved) }
            another.append(s)
        }

        almost.sort(by: rank)
        another.sort(by: rank)
        return Array((almost + another).prefix(options.maxFinishRow).map(\.suggestion))
    }

    private static func isTimeReason(_ r: PlayNextReason) -> Bool {
        switch r {
        case .remainingTime, .fitsBracket: return true
        default: return false
        }
    }

    private static func cites(_ r: PlayNextReason, _ exemplar: GameID?) -> Bool {
        guard let exemplar else { return false }
        switch r {
        case let .sharedFranchise(_, with): return with == exemplar
        case let .sharedSeries(_, with): return with == exemplar
        case let .sameDeveloper(_, e): return e == exemplar
        case let .similarTo(e): return e == exemplar
        default: return false
        }
    }

    // MARK: Play it again

    /// The replay eligibility rule over one finished candidate, before the time fit (pure;
    /// tested directly): `.eligible(lastPlayedYear)`, `.undated` (would be eligible but has no
    /// importer date — counted for the footer), or nil (not a replay candidate).
    enum ReplayEligibility: Equatable {
        case eligible(lastPlayedYear: Int)
        case undated
    }

    static func replayEligibility(_ c: Candidate, now: Double, weights: RecommendationWeights,
                                  calendar: Calendar = Calendar(identifier: .gregorian)) -> ReplayEligibility? {
        guard c.status == .finished, c.holdsUp == .holdsUp,
              let tier = c.tierLetter, weights.replayTierLetters.contains(tier) else { return nil }
        guard let last = c.lastPlayedAt else { return .undated }
        guard now - last.timeIntervalSince1970 >= weights.replayMinGapSeconds else { return nil }
        return .eligible(lastPlayedYear: calendar.component(.year, from: last))
    }

    private static func replayRow(_ input: RecommendationInput) -> (suggestions: [PlayNextSuggestion], undated: Int) {
        let weights = input.weights
        let options = input.options
        let bracket = input.bracket
        let style = bracket.resolvedStyle
        var undated = 0
        var scored: [Scored] = []

        for c in input.replayCandidates {
            guard passesRowGates(c, feedback: input.feedback, now: options.now),
                  let eligibility = replayEligibility(c, now: options.now, weights: weights) else { continue }
            guard case let .eligible(year) = eligibility else { undated += 1; continue }
            guard let full = c.fullEstimate(style: style, paceFactor: bracket.paceFactor) else { continue }
            let fit = TimeFit.evaluate(estimateSeconds: full, bracket: bracket, weights: weights)
            guard !fit.excluded else { continue }
            let tier = c.tierLetter ?? ""
            let base = weights.replayTierScore[tier] ?? 0.5
            let jitter = rotationJitter(seed: options.seed, id: c.id, magnitude: weights.rotationMagnitude)
            let picked = input.feedback.picked.contains(c.id) ? weights.pickedPenalty : 0
            let final = clamp(base + weights.timeFitWeight * (fit.fit - 1) + jitter - picked)
            let suggestion = PlayNextSuggestion(
                id: c.id, title: c.title, year: c.year, coverFile: c.coverFile,
                platformIDs: c.platformIDs, formats: c.formats, status: c.playStatus,
                estimateSeconds: full, fullEstimateSeconds: full,
                score: final,
                matchStrength: tier == "S" ? .strong : .fair,
                reasons: [.replayWorthy(tierLetter: tier, lastPlayedYear: year),
                          .fitsBracket(estimateSeconds: full, bracket: bracket),
                          .markedHoldsUp],
                hasMetadata: c.hasMetadata, igdbID: c.igdbID, holdsUp: c.holdsUp,
                firstPlayedAt: c.firstPlayedAt)
            scored.append(Scored(id: c.id, finalScore: final, suggestion: suggestion))
        }
        scored.sort(by: rank)
        return (Array(scored.prefix(options.maxReplayRow).map(\.suggestion)), undated)
    }
}
