import Foundation
import Testing
@testable import VGN

/// Pure tests for the ``PlayedMark`` value type: labels, menu titles, persistence
/// round-trip, the ordered choice list and the banner feedback text.
struct PlayedMarkTests {

    @Test func labelsMatchPlayStatus() {
        #expect(PlayedMark.played.label == "Played")
        #expect(PlayedMark.status(.playing).label == "Playing")
        #expect(PlayedMark.status(.finished).label == "Finished")
        #expect(PlayedMark.status(.completed).label == "100%")
        #expect(PlayedMark.status(.abandoned).label == "Abandoned")
    }

    @Test func menuTitleIsMarkAsLabel() {
        #expect(PlayedMark.played.menuTitle == "Mark as Played")
        #expect(PlayedMark.status(.finished).menuTitle == "Mark as Finished")
        #expect(PlayedMark.status(.completed).menuTitle == "Mark as 100%")
    }

    @Test func statusIsNilForPlainPlayed() {
        #expect(PlayedMark.played.status == nil)
        #expect(PlayedMark.status(.abandoned).status == .abandoned)
    }

    @Test func allCasesInMenuOrder() {
        #expect(PlayedMark.allCases == [
            .played, .status(.playing), .status(.finished),
            .status(.completed), .status(.abandoned),
        ])
    }

    @Test func storageRoundTrips() {
        for mark in PlayedMark.allCases {
            #expect(PlayedMark(storageKey: mark.storageKey) == mark)
        }
        #expect(PlayedMark.played.storageKey == "played")
        #expect(PlayedMark.status(.finished).storageKey == "finished")
        #expect(PlayedMark(storageKey: "nonsense") == nil)
    }

    @Test func bannerChangedOnly() {
        #expect(PlayedMarkFeedback.banner(mark: .status(.finished), changed: 1, already: 0)
                == "^[1 game](inflect: true) marked Finished.")
        #expect(PlayedMarkFeedback.banner(mark: .status(.finished), changed: 12, already: 0)
                == "^[12 game](inflect: true) marked Finished.")
        #expect(PlayedMarkFeedback.banner(mark: .played, changed: 3, already: 0)
                == "^[3 game](inflect: true) marked Played.")
    }

    @Test func bannerAlreadyOnly() {
        #expect(PlayedMarkFeedback.banner(mark: .status(.finished), changed: 0, already: 3)
                == "^[3 game](inflect: true) already Finished — unchanged.")
    }

    @Test func bannerMixed() {
        #expect(PlayedMarkFeedback.banner(mark: .status(.finished), changed: 2, already: 1)
                == "^[2 game](inflect: true) marked Finished · 1 already Finished.")
    }
}

/// Pure tests for the ``LastPlayedMarkStoring`` implementations.
struct LastPlayedMarkPreferenceTests {

    @Test func inMemoryDefaultsToPlayed() {
        let prefs = InMemoryLastPlayedMarkPreferences()
        #expect(prefs.lastPlayedMark() == .played)
    }

    @Test func inMemoryPersistsWithinInstance() {
        let prefs = InMemoryLastPlayedMarkPreferences()
        prefs.setLastPlayedMark(.status(.completed))
        #expect(prefs.lastPlayedMark() == .status(.completed))
    }

    @Test func userDefaultsRoundTrips() {
        let suite = UserDefaults(suiteName: "VGNTests-mark-\(UUID().uuidString)")!
        let prefs = UserDefaultsLastPlayedMarkPreferences(defaults: suite)
        #expect(prefs.lastPlayedMark() == .played)     // nothing stored yet
        prefs.setLastPlayedMark(.status(.abandoned))
        #expect(prefs.lastPlayedMark() == .status(.abandoned))
        // A fresh reader over the same suite sees the persisted value.
        #expect(UserDefaultsLastPlayedMarkPreferences(defaults: suite).lastPlayedMark()
                == .status(.abandoned))
    }
}
