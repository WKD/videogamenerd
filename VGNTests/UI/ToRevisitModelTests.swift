import Foundation
import Testing
@testable import VGN

/// The model side of "To Revisit" (PLAN §4/§7b): the ``PlayStatus`` ⇄ `(status, revisit)`
/// mapping, its ordering, the ``PlayedMark`` round-trip, and the mixed-state menu marks.
@Suite struct ToRevisitModelTests {

    // MARK: - PlayStatus ⇄ DB pair

    @Test func toRevisitMapsToAbandonedPlusFlag() {
        #expect(PlayStatus.toRevisit.dbStatus == "abandoned")
        #expect(PlayStatus.toRevisit.dbRevisit == 1)
        #expect(PlayStatus.abandoned.dbStatus == "abandoned")
        #expect(PlayStatus.abandoned.dbRevisit == 0)
        // Every other status clears the flag.
        for s in [PlayStatus.playing, .finished, .completed] {
            #expect(s.dbRevisit == 0)
            #expect(s.dbStatus == s.rawValue)   // legacy strings are unchanged
        }
    }

    @Test func fromDBPairReconstructsStatus() {
        #expect(PlayStatus.from(dbStatus: "abandoned", revisit: true) == .toRevisit)
        #expect(PlayStatus.from(dbStatus: "abandoned", revisit: false) == .abandoned)
        #expect(PlayStatus.from(dbStatus: "playing", revisit: false) == .playing)
        // A stray revisit flag on a non-abandoned status never invents To Revisit.
        #expect(PlayStatus.from(dbStatus: "finished", revisit: true) == .finished)
        #expect(PlayStatus.from(dbStatus: nil, revisit: false) == nil)
        #expect(PlayStatus.from(dbStatus: "garbage", revisit: true) == nil)
    }

    /// Legacy decode: the four v1 raw values still decode, and 'toRevisit' only appears in
    /// new (model-level) serialisation — never written to `games.status`.
    @Test func legacyRawValuesStillDecode() throws {
        for raw in ["playing", "finished", "completed", "abandoned"] {
            #expect(PlayStatus(rawValue: raw) != nil)
        }
        #expect(PlayStatus.toRevisit.rawValue == "toRevisit")
        // Codable round-trip of the new value (new files only).
        let data = try JSONEncoder().encode(PlayStatus.toRevisit)
        #expect(try JSONDecoder().decode(PlayStatus.self, from: data) == .toRevisit)
    }

    /// "To Revisit" sits right after "Abandoned" everywhere statuses are listed.
    @Test func orderingPutsToRevisitAfterAbandoned() {
        #expect(PlayStatus.allCases == [.playing, .finished, .completed, .abandoned, .toRevisit])
        #expect(PlayStatus.toRevisit.label == "To Revisit")
    }

    // MARK: - PlayedMark (⇧M last-used memory)

    @Test func playedMarkRoundTripsToRevisit() {
        let mark = PlayedMark.status(.toRevisit)
        #expect(mark.storageKey == "toRevisit")
        #expect(PlayedMark(storageKey: mark.storageKey) == mark)   // ⇧M last-used remembers it
        #expect(mark.label == "To Revisit")
        // It is offered in the menu, right after Abandoned.
        #expect(PlayedMark.allCases.last == .status(.toRevisit))
        #expect(PlayedMark.allCases == [.played, .status(.playing), .status(.finished),
                                        .status(.completed), .status(.abandoned), .status(.toRevisit)])
    }

    @Test func lastUsedPreferencesRememberToRevisit() {
        let defaults = UserDefaults(suiteName: "ToRevisitLastUsedTest.\(UUID().uuidString)")!
        let prefs = UserDefaultsLastPlayedMarkPreferences(defaults: defaults)
        prefs.setLastPlayedMark(.status(.toRevisit))
        #expect(prefs.lastPlayedMark() == .status(.toRevisit))
    }

    // MARK: - Mixed-state menu marks over a mixed selection

    @Test func mixedStateMenuDistinguishesAbandonedFromToRevisit() {
        func g(_ id: Int64, _ status: PlayStatus?) -> GameSummary {
            GameSummary(id: id, title: "G\(id)", played: status != nil, status: status)
        }
        // Selection mixing Abandoned / To Revisit / none.
        let selection = [g(1, .abandoned), g(2, .toRevisit), g(3, nil)]

        // Each status marks only its own games → both are "some" (mixed dash), disjoint.
        #expect(selection.playedMarkState(.status(.abandoned)) == .some)
        #expect(selection.playedMarkState(.status(.toRevisit)) == .some)

        // A selection that is entirely To Revisit → all (✓) for To Revisit, none for Abandoned.
        let allRevisit = [g(1, .toRevisit), g(2, .toRevisit)]
        #expect(allRevisit.playedMarkState(.status(.toRevisit)) == .all)
        #expect(allRevisit.playedMarkState(.status(.abandoned)) == .none)
    }
}
