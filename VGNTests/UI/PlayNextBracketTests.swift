import Foundation
import Testing
@testable import VGN

/// Feature: Play Next's time brackets are the five "By Length" ``LengthShelf`` shelves
/// (owner request 2026-09-19), sharing one source of truth for names + hour bounds and
/// the same weekly ``PlayPace`` as the sidebar. These cover the bounds parity, the old
/// preset → shelf migration, the pace-driven recompute + custom pre-fill, and the
/// sidebar → Play Next preselect. Model tests are serialized (they touch a UserDefaults
/// suite and the @MainActor model), with hard timeouts.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayNextBracketTests {

    // MARK: - Helpers

    private func ephemeral() -> UserDefaults {
        UserDefaults(suiteName: "playnext.bracket.\(UUID().uuidString)")!
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async {
        let start = ContinuousClock.now
        while !cond() {
            if ContinuousClock.now - start > timeout { break }
            try? await Task.sleep(for: .milliseconds(4))
        }
    }

    // MARK: - Bounds parity (sidebar shelf ⇔ Play Next bracket)

    @Test func bracketBoundsMatchSidebarShelvesAcrossPaces() {
        for hours in [2.0, 8.0, 20.0] {
            let pace = PlayPace(hoursPerWeek: hours)
            let bounds = LengthShelf.bounds(for: pace)
            for shelf in LengthShelf.allCases {
                let bracket = TimeBracket(shelf: shelf, pace: pace)
                let expected = shelf.secondsRange(in: bounds)
                #expect(bracket.lowerSeconds == expected.lower,
                        "lower mismatch for \(shelf) at \(hours) h/week")
                #expect(bracket.upperSeconds == expected.upper,
                        "upper mismatch for \(shelf) at \(hours) h/week")
            }
            // The open ends: One Evening has no floor, Epics no ceiling.
            #expect(TimeBracket(shelf: .evening, pace: pace).lowerSeconds == nil)
            #expect(TimeBracket(shelf: .epic, pace: pace).upperSeconds == nil)
        }
    }

    @Test func labelAndRangeShowTheHourRange() {
        // Default pace 8 ⇒ edges 4 / 10 / 40 / 80.
        #expect(TimeBracket(shelf: .evening).rangeText == "under 4 h")
        #expect(TimeBracket(shelf: .fewWeeks).rangeText == "10–40 h")
        #expect(TimeBracket(shelf: .epic).rangeText == "80 h and more")
        // The label (used in reasons / the Ask Claude prompt) carries name + range.
        #expect(TimeBracket(shelf: .fewWeeks).label == "A Few Weeks (10–40 h)")
        #expect(TimeBracket(budgetSeconds: 16 * 3600).label == "~16 h budget")
    }

    // MARK: - Legacy preset → shelf migration

    @Test func legacyPresetRawValuesMigrateToNearestShelf() {
        let cases: [(String, LengthShelf)] = [
            ("evening", .evening),
            ("weekOrTwo", .weekend),
            ("month", .fewWeeks),
            ("longHaul", .season),
            ("epic", .epic),           // already a valid new value
            ("totally-unknown", .fewWeeks),
        ]
        for (raw, expected) in cases {
            let defaults = ephemeral()
            defaults.set(raw, forKey: "playNext.preset")
            let model = PlayNextModel(backend: ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult()),
                                      secondOpinion: StubSecondOpinionProvider(),
                                      defaults: defaults, recomputeDebounce: .milliseconds(1))
            #expect(model.bracketShelf == expected, "‘\(raw)’ should migrate to \(expected)")
        }
    }

    // MARK: - Pace drives bounds + one recompute

    @Test func paceChangeRecomputesOnceWithNewBounds() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: ephemeral(), pace: PlayPace(hoursPerWeek: 8),
                                  recomputeDebounce: .milliseconds(1))
        model.selectShelf(.fewWeeks)
        await model.start()
        await waitUntil { model.hasLoaded }
        let before = backend.recommendCalls.count

        model.setPace(PlayPace(hoursPerWeek: 20))
        await waitUntil { backend.recommendCalls.count > before }
        // Exactly one recompute for the pace change.
        #expect(backend.recommendCalls.count == before + 1)
        // The new bracket carries the new pace's bounds (A Few Weeks at 20 h/week).
        let bounds = LengthShelf.bounds(for: PlayPace(hoursPerWeek: 20))
        #expect(backend.recommendCalls.last?.bracket.upperSeconds
                == LengthShelf.fewWeeks.secondsRange(in: bounds).upper)
    }

    @Test func paceChangeToSameValueIsANoOp() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: ephemeral(), pace: PlayPace(hoursPerWeek: 8),
                                  recomputeDebounce: .milliseconds(1))
        await model.start()
        await waitUntil { model.hasLoaded }
        let before = backend.recommendCalls.count
        model.setPace(PlayPace(hoursPerWeek: 8))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(backend.recommendCalls.count == before)
    }

    // MARK: - Custom pre-fill from pace

    @Test func customHoursPrefillFromPaceUnlessOverridden() {
        // A fresh model at 20 h/week pre-fills custom hours/week from the pace.
        let defaults = ephemeral()
        let m1 = PlayNextModel(backend: ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult()),
                               secondOpinion: StubSecondOpinionProvider(),
                               defaults: defaults, pace: PlayPace(hoursPerWeek: 20),
                               recomputeDebounce: .milliseconds(1))
        #expect(m1.customHoursPerWeek == 20)

        // An explicit choice is remembered and NOT re-seeded by the pace.
        m1.useCustom(hoursPerWeek: 5, weeks: 2)
        let m2 = PlayNextModel(backend: ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult()),
                               secondOpinion: StubSecondOpinionProvider(),
                               defaults: defaults, pace: PlayPace(hoursPerWeek: 20),
                               recomputeDebounce: .milliseconds(1))
        #expect(m2.customHoursPerWeek == 5)
    }

    @Test func paceChangeReseedsCustomPrefillUntilOverridden() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.emptyResult())
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: ephemeral(), pace: PlayPace(hoursPerWeek: 8),
                                  recomputeDebounce: .milliseconds(1))
        #expect(model.customHoursPerWeek == 8)
        model.setPace(PlayPace(hoursPerWeek: 20))
        #expect(model.customHoursPerWeek == 20)   // pre-fill follows the pace
    }

    // MARK: - Sidebar → Play Next preselect (one-shot hint)

    @Test func bracketHintPreselectsMatchingShelfOnStart() async {
        let backend = ScriptedPlayNextBackend(result: PlayNextSamples.richResult())
        let model = PlayNextModel(backend: backend, secondOpinion: StubSecondOpinionProvider(),
                                  defaults: ephemeral(), bracketHint: { .season },
                                  recomputeDebounce: .milliseconds(1))
        await model.start()
        #expect(!model.usesCustom)
        #expect(model.bracketShelf == .season)
    }

    // MARK: - Ask Claude prompt wording

    @Test func secondOpinionPromptCarriesShelfNameAndRange() {
        let bracket = TimeBracket(shelf: .fewWeeks)   // "A Few Weeks (10–40 h)"
        let request = SecondOpinionRequest(
            bracket: bracket.label, completionist: false,
            topRanked: [], didntClick: [],
            shortlist: [.init(id: 1, title: "X", platform: nil, format: nil,
                              estimateHours: 20, status: "backlog", engineRank: 1)],
            engineOrdering: [1])
        let prompt = SecondOpinionPrompt.build(for: request)
        #expect(prompt.contains("A Few Weeks (10–40 h)"))
    }

    @Test func viewModelHintIsOneShot() async {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: []),
                                  playPacePreferences: InMemoryPlayPacePreferences())
        vm.select(.length(.epic))
        #expect(vm.consumePlayNextBracketHint() == .epic)
        #expect(vm.consumePlayNextBracketHint() == nil)   // consumed
    }
}
