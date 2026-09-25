import Foundation
import Testing
@testable import VGN

/// "Finish what you started" (Almost there / Worth another try) and "Play it again" (Worth
/// replaying) — PLAN §7b "Scheduled 2026-09-25", wave 22. Pure engine tests on synthetic
/// libraries: each pool's eligibility table, the remaining-time fit, reasons, exclusions
/// (Too Archaic, snoozed, never), no duplication with the regular picks, the replay gap +
/// the undated footer count, and backtest neutrality.
@Suite struct FinishAndReplayRowsTests {
    private let weights = RecommendationWeights()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09

    private func profile() -> [RankedGame] {
        (1...16).map { Rec.ranked(GameID($0), score: 0.5, [Rec.trait(.genre, "RPG")]) }
    }

    private func run(_ candidates: [Candidate], replay: [Candidate] = [], ranked: [RankedGame]? = nil,
                     bracket: TimeBracket = Rec.month(), feedback: RecFeedbackState = RecFeedbackState(),
                     includeAbandoned: Bool = false) -> PlayNextResult {
        RecommendationEngine.recommend(RecommendationInput(
            ranked: ranked ?? profile(), candidates: candidates, replayCandidates: replay,
            bracket: bracket, feedback: feedback,
            options: RecommendationOptions(includeAbandoned: includeAbandoned, seed: 0,
                                           now: now.timeIntervalSince1970)))
    }

    // MARK: - Almost there: eligibility table

    @Test func almostThereEligibilityTable() {
        // (status, played h of a 20 h game) → pool?
        let cases: [(RecCandidateStatus, Double?, RecommendationEngine.FinishPool?)] = [
            (.playing, 14, .almostThere(remainingSeconds: Rec.hours(6), pastEstimate: false)),   // exactly 70 %
            (.playing, 13.9, nil),                                                             // just under
            (.toRevisit, 18, .almostThere(remainingSeconds: Rec.hours(2), pastEstimate: false)),
            (.playing, 20, .almostThere(remainingSeconds: 30 * 60, pastEstimate: true)),       // at the estimate → floor
            (.playing, 26, .almostThere(remainingSeconds: 30 * 60, pastEstimate: true)),       // past it
            (.playing, 19.9, .almostThere(remainingSeconds: 30 * 60, pastEstimate: false)),    // 6 min left → floor 30 min
            (.playing, nil, nil),                                                              // no play time
            (.backlog, 18, nil),
            (.playedUnknown, 18, nil),
            (.finished, 18, nil),
            (.abandoned, 18, nil),                                                             // abandoned late: neither pool
        ]
        for (status, played, expected) in cases {
            let c = Rec.candidate(1, status: status, estimateHours: 20, playedHours: played)
            let pool = RecommendationEngine.finishPool(c, fullSeconds: Rec.hours(20), weights: weights)
            #expect(pool == expected, "\(status) \(String(describing: played))")
        }
        // No length ⇒ no pool.
        let unknown = Rec.candidate(1, status: .playing, playedHours: 5)
        #expect(RecommendationEngine.finishPool(unknown, fullSeconds: nil, weights: weights) == nil)
    }

    @Test func worthAnotherTryEligibilityTable() {
        let cases: [(RecCandidateStatus, Double?, Bool)] = [
            (.abandoned, 3, true),      // 15 %
            (.abandoned, 4.9, true),    // just under 25 %
            (.abandoned, 5, false),     // exactly 25 % — not "early"
            (.abandoned, nil, false),   // no play time → no "dropped after N h"
            (.toRevisit, 3, false),     // To Revisit is a regular candidate, never this pool
        ]
        for (status, played, eligible) in cases {
            let c = Rec.candidate(1, status: status, estimateHours: 20, playedHours: played)
            let pool = RecommendationEngine.finishPool(c, fullSeconds: Rec.hours(20), weights: weights)
            if case .droppedEarly = pool { #expect(eligible, "\(status) \(String(describing: played))") }
            else { #expect(!eligible, "\(status) \(String(describing: played))") }
        }
    }

    @Test func thresholdsUseThePaceAdjustedLength() {
        // 20 h advertised, 16 h played = 80 % → Almost there at 1.0×; at 1.5× the length is 30 h
        // and 16 h is only 53 % → not yet.
        let c = Rec.candidate(100, status: .playing, estimateHours: 20, playedHours: 16, playStatus: .playing)
        let atOne = run([c])
        #expect(atOne.finishWhatYouStarted.map(\.id) == [100])
        let atSlow = run([c], bracket: TimeBracket(shelf: .fewWeeks, playStyle: .storyFirst, paceFactor: 1.5))
        #expect(atSlow.finishWhatYouStarted.isEmpty)
        #expect(atSlow.shortlist.map(\.id) == [100])   // still a regular pick (remaining 14 h)
    }

    // MARK: - Remaining-time fit + reasons

    @Test func almostThereIsFittedOnTheRemainingTimeWithItsReason() throws {
        // A 60 h epic with 50 h played: 10 h left fits "A Weekend" (4–10 h) even though the
        // full length never would.
        let c = Rec.candidate(100, status: .playing, estimateHours: 60, playedHours: 50,
                              title: "Epic", playStatus: .playing)
        let result = run([c], bracket: TimeBracket(shelf: .weekend, playStyle: .storyFirst))
        let card = try #require(result.finishWhatYouStarted.first)
        #expect(card.id == 100)
        #expect(card.estimateSeconds == Rec.hours(10))
        #expect(card.fullEstimateSeconds == Rec.hours(60))
        #expect(card.reasons.first == .almostThere(remainingSeconds: Rec.hours(10), pastEstimate: false))
        #expect(!card.reasons.contains { if case .remainingTime = $0 { true } else { false } })
        let sentences = PlayNextReasonFormatter.sentences(for: card, exemplars: [:], bracket: result.bracket)
        #expect(sentences.first == "About 10 h left")
        // Remaining 10 h is too long for "One Evening" (< 4 h, hard limit 6 h) → not shown.
        #expect(run([c], bracket: Rec.evening()).finishWhatYouStarted.isEmpty)
    }

    @Test func pastTheEstimateStillEligibleWithItsOwnSentence() throws {
        let c = Rec.candidate(100, status: .playing, estimateHours: 10, playedHours: 12, playStatus: .playing)
        let card = try #require(run([c], bracket: Rec.evening()).finishWhatYouStarted.first)
        #expect(card.estimateSeconds == 30 * 60)
        #expect(PlayNextReasonFormatter.sentence(for: card.reasons[0], exemplars: [:], bracket: Rec.evening())
                == "Past the estimate — maybe finish it?")
    }

    // MARK: - Worth another try: the taste test

    /// A library where "Souls" games are loved (S tier) and the rest is middling.
    private func soulsProfile() -> [RankedGame] {
        var ranked = (1...16).map { Rec.ranked(GameID($0), score: 0.4, [Rec.trait(.genre, "Puzzle")]) }
        ranked.append(RankedGame(id: 50, score: 0.98, traits: [Rec.trait(.franchise, "Souls"), Rec.trait(.genre, "RPG")],
                                 tierLetter: "S"))
        ranked.append(RankedGame(id: 51, score: 0.3, traits: [Rec.trait(.franchise, "Kart")], tierLetter: "C"))
        return ranked
    }

    @Test func droppedEarlyWithALovedSequelQualifiesAndSaysSo() throws {
        let dropped = Rec.candidate(100, status: .abandoned, estimateHours: 30, playedHours: 3,
                                    traits: [Rec.trait(.franchise, "Souls")], title: "Souls II",
                                    playStatus: .abandoned)
        let result = run([dropped], ranked: soulsProfile())
        let card = try #require(result.finishWhatYouStarted.first)
        #expect(card.reasons.first == .droppedEarly(playedSeconds: Rec.hours(3), lovedExemplar: 50))
        // The franchise reason citing the same game is not repeated.
        #expect(!card.reasons.contains(.sharedFranchise(value: "Souls", with: 50)))
        let sentence = PlayNextReasonFormatter.sentence(
            for: card.reasons[0], exemplars: [50: ExemplarInfo(title: "Dark Souls", tierLetter: "S")],
            bracket: result.bracket)
        #expect(sentence == "You dropped it after 3 h — you loved **Dark Souls** (S)")
    }

    @Test func droppedEarlyNeedsAStrongMatch() {
        // Linked only to a C game, and among many better backlog candidates → not top quartile.
        let dropped = Rec.candidate(100, status: .abandoned, estimateHours: 30, playedHours: 3,
                                    traits: [Rec.trait(.franchise, "Kart")], playStatus: .abandoned)
        let backlog = (200..<208).map {
            Rec.candidate(GameID($0), estimateHours: 20, traits: [Rec.trait(.franchise, "Souls")])
        }
        let result = run([dropped] + backlog, ranked: soulsProfile())
        #expect(result.finishWhatYouStarted.isEmpty)
    }

    @Test func droppedEarlyQualifiesOnTopQuartileAlone() throws {
        // No direct link, but the best taste match of everything fitting the bracket.
        let dropped = Rec.candidate(100, status: .abandoned, estimateHours: 30, playedHours: 3,
                                    traits: [Rec.trait(.genre, "RPG")], playStatus: .abandoned)
        let meh = (200..<207).map { Rec.candidate(GameID($0), estimateHours: 20, traits: [Rec.trait(.genre, "Puzzle")]) }
        let result = run([dropped] + meh, ranked: soulsProfile())
        let card = try #require(result.finishWhatYouStarted.first)
        #expect(card.reasons.first == .droppedEarly(playedSeconds: Rec.hours(3), lovedExemplar: nil))
        #expect(PlayNextReasonFormatter.sentence(for: card.reasons[0], exemplars: [:], bracket: result.bracket)
                == "You dropped it after 3 h — a strong match for your taste")
    }

    @Test func topQuartileThreshold() {
        #expect(RecommendationEngine.topQuantileThreshold([], quantile: 0.75) == nil)
        #expect(RecommendationEngine.topQuantileThreshold([0.1], quantile: 0.75) == 0.1)
        // 8 scores → top 2.
        #expect(RecommendationEngine.topQuantileThreshold([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], quantile: 0.75) == 0.7)
        // 5 scores → top ceil(1.25) = 2.
        #expect(RecommendationEngine.topQuantileThreshold([0.5, 0.1, 0.9, 0.3, 0.7], quantile: 0.75) == 0.7)
    }

    // MARK: - Exclusions + no duplication

    @Test func archaicSnoozedAndNeverAreKeptOut() {
        func almost(_ id: GameID, _ mark: HoldsUp? = nil) -> Candidate {
            Rec.candidate(id, status: .playing, estimateHours: 20, playedHours: 18, playStatus: .playing, holdsUp: mark)
        }
        let feedback = RecFeedbackState(snoozedUntil: [101: now.timeIntervalSince1970 + 3600], never: [102])
        // Archaic stays out even with "Include archaic" (the rows never show it).
        let result = RecommendationEngine.recommend(RecommendationInput(
            ranked: profile(), candidates: [almost(100, .tooArchaic), almost(101), almost(102), almost(103)],
            bracket: Rec.month(), feedback: feedback,
            options: RecommendationOptions(includeArchaic: true, seed: 0, now: now.timeIntervalSince1970)))
        #expect(result.finishWhatYouStarted.map(\.id) == [103])
        // An expired snooze is eligible again.
        let later = RecFeedbackState(snoozedUntil: [101: now.timeIntervalSince1970 - 1])
        #expect(run([almost(101)], feedback: later).finishWhatYouStarted.map(\.id) == [101])
    }

    @Test func aGameInTheFinishRowIsNotRepeatedInTheRegularPicks() {
        let almost = Rec.candidate(100, status: .playing, estimateHours: 20, playedHours: 18, playStatus: .playing)
        let other = Rec.candidate(101, estimateHours: 20)
        let result = run([almost, other])
        #expect(result.finishWhatYouStarted.map(\.id) == [100])
        #expect(result.shortlist.map(\.id) == [101])
        // …and with "Include abandoned" on, a worth-another-try game is not repeated either.
        let dropped = Rec.candidate(102, status: .abandoned, estimateHours: 30, playedHours: 3,
                                    traits: [Rec.trait(.franchise, "Souls")], playStatus: .abandoned)
        let withAbandoned = run([dropped, other], ranked: soulsProfile(), includeAbandoned: true)
        #expect(withAbandoned.finishWhatYouStarted.map(\.id) == [102])
        #expect(!withAbandoned.shortlist.contains { $0.id == 102 })
    }

    @Test func rowIsCappedAndAlmostThereLeads() {
        let almost = (100..<104).map {
            Rec.candidate(GameID($0), status: .playing, estimateHours: 20, playedHours: 18, playStatus: .playing)
        }
        let dropped = (200..<204).map {
            Rec.candidate(GameID($0), status: .abandoned, estimateHours: 30, playedHours: 3,
                          traits: [Rec.trait(.franchise, "Souls")], playStatus: .abandoned)
        }
        let row = run(almost + dropped, ranked: soulsProfile()).finishWhatYouStarted
        #expect(row.count == 5)
        #expect(Set(row.prefix(4).map(\.id)) == Set(100..<104))
        #expect((200..<204).contains(row[4].id))
    }

    // MARK: - Play it again

    private func finished(_ id: GameID, tier: String? = "S", mark: HoldsUp? = .holdsUp,
                          lastPlayed: Date?, hours: Double = 12) -> Candidate {
        Candidate(id: id, estimateSeconds: Rec.hours(hours), status: .finished, title: "F\(id)",
                  playStatus: .finished, holdsUp: mark, lastPlayedAt: lastPlayed, tierLetter: tier)
    }

    private func yearsAgo(_ years: Double) -> Date {
        now.addingTimeInterval(-years * 365.2425 * 24 * 3600)
    }

    @Test func replayEligibilityTable() {
        let cases: [(Candidate, RecommendationEngine.ReplayEligibility?)] = [
            (finished(1, lastPlayed: yearsAgo(7)), .eligible(lastPlayedYear: 2019)),
            (finished(2, tier: "A", lastPlayed: yearsAgo(3.01)), .eligible(lastPlayedYear: 2023)),
            (finished(3, lastPlayed: yearsAgo(2.9)), nil),                       // too recent
            (finished(4, tier: "B", lastPlayed: yearsAgo(7)), nil),              // not S/A
            (finished(5, tier: nil, lastPlayed: yearsAgo(7)), nil),              // unranked
            (finished(6, mark: .ofItsTime, lastPlayed: yearsAgo(7)), nil),       // must hold up
            (finished(7, mark: nil, lastPlayed: yearsAgo(7)), nil),              // unrated ≠ holds up
            (finished(8, lastPlayed: nil), .undated),                            // footer count only
            (Rec.candidate(9, status: .playing, estimateHours: 10, holdsUp: .holdsUp), nil),
        ]
        for (c, expected) in cases {
            #expect(RecommendationEngine.replayEligibility(c, now: now.timeIntervalSince1970, weights: weights) == expected,
                    "id \(c.id)")
        }
    }

    @Test func replayRowFitsTheBracketAndCountsTheUndated() throws {
        let replay = [
            finished(1, lastPlayed: yearsAgo(7), hours: 12),          // fits A Few Weeks
            finished(2, tier: "A", lastPlayed: yearsAgo(5), hours: 20),
            finished(3, lastPlayed: yearsAgo(7), hours: 90),          // beyond the hard limit
            finished(4, lastPlayed: nil),
            finished(5, tier: "A", lastPlayed: nil),
            finished(6, tier: "B", lastPlayed: nil),                  // not eligible → not counted
        ]
        let result = run([], replay: replay)
        #expect(result.replay.map(\.id) == [1, 2])                   // S before A
        #expect(result.replayUndatedCount == 2)
        let card = try #require(result.replay.first)
        #expect(card.reasons.first == .replayWorthy(tierLetter: "S", lastPlayedYear: 2019))
        #expect(PlayNextReasonFormatter.sentence(for: card.reasons[0], exemplars: [:], bracket: result.bracket)
                == "You gave it S · last played 2019")
        #expect(card.estimateSeconds == Rec.hours(12))
        #expect(PlayNextExtraRowCopy.replayFooter(undatedCount: result.replayUndatedCount)
                == "2 more have no last-played date")
        #expect(PlayNextExtraRowCopy.replayFooter(undatedCount: 1) == "1 more has no last-played date")
        #expect(PlayNextExtraRowCopy.replayFooter(undatedCount: 0) == nil)
    }

    @Test func replayHonoursSnoozeNeverAndArchaicAndNeverMixesIntoPicks() {
        let replay = [finished(1, lastPlayed: yearsAgo(7)), finished(2, lastPlayed: yearsAgo(7)),
                      finished(3, lastPlayed: yearsAgo(7))]
        let feedback = RecFeedbackState(snoozedUntil: [1: now.timeIntervalSince1970 + 60], never: [2])
        let result = run([Rec.candidate(100, estimateHours: 20)], replay: replay, feedback: feedback)
        #expect(result.replay.map(\.id) == [3])
        #expect(result.shortlist.map(\.id) == [100])
        // A finished game passed as a regular candidate is never a regular pick.
        let stray = run([finished(9, lastPlayed: yearsAgo(7))])
        #expect(stray.shortlist.isEmpty)
        #expect(stray.exclusions.total == 0)
    }

    // MARK: - Rows show / hide (model level)

    @Test func rowsShowExactlyWhenTheyHaveCards() {
        let empty = PlayNextResult(bracket: Rec.month())
        #expect(!PlayNextExtraRowCopy.showsFinishRow(empty))
        #expect(!PlayNextExtraRowCopy.showsReplayRow(empty))
        #expect(!PlayNextExtraRowCopy.showsFinishRow(nil))
        #expect(empty.isEmpty)
        let s = PlayNextSuggestion(id: 1, title: "X", score: 0.5, matchStrength: .fair, reasons: [], hasMetadata: true)
        let finish = PlayNextResult(bracket: Rec.month(), finishWhatYouStarted: [s])
        #expect(PlayNextExtraRowCopy.showsFinishRow(finish))
        #expect(!finish.isEmpty)
        // An undated count alone never shows the replay row (hidden when empty).
        let undatedOnly = PlayNextResult(bracket: Rec.month(), replayUndatedCount: 12)
        #expect(!PlayNextExtraRowCopy.showsReplayRow(undatedOnly))
        #expect(PlayNextExtraRowCopy.showsReplayRow(PlayNextResult(bracket: Rec.month(), replay: [s])))
    }

    // MARK: - Backtest neutrality

    @Test func backtestUnchangedByTierLettersAndRows() {
        // The backtest predicts taste from ranked games only: the new tier letter on a ranked
        // game (used only by Worth another try) and the new rows / pace factor are no input.
        let plain = soulsProfile().map { RankedGame(id: $0.id, igdbID: $0.igdbID, score: $0.score, traits: $0.traits) }
        let lettered = soulsProfile()
        #expect(TasteBacktest.run(ranked: plain).spearman == TasteBacktest.run(ranked: lettered).spearman)
    }
}
