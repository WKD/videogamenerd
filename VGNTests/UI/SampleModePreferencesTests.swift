import Foundation
import Testing
@testable import VGN

/// D5: in `-VGNSampleData` / `-VGNSeedGames` (and under the test host), UI preferences are
/// isolated from the owner's real `UserDefaults.standard`, so a demo / perf run never
/// writes the owner's real pace, play style, PS Plus deadline or sort order.
struct SampleModePreferencesTests {

    @Test("A sample / seeded launch (or the test host) isolates preferences")
    func isolationDecision() {
        #expect(AppPreferences.wantsIsolatedDefaults(isTestHost: false, sampleData: true, seedGames: 0))
        #expect(AppPreferences.wantsIsolatedDefaults(isTestHost: false, sampleData: false, seedGames: 5))
        #expect(AppPreferences.wantsIsolatedDefaults(isTestHost: true, sampleData: false, seedGames: 0))
        // A normal live launch keeps the real domain.
        #expect(!AppPreferences.wantsIsolatedDefaults(isTestHost: false, sampleData: false, seedGames: 0))
    }

    @Test("Changing the pace / style on an isolated suite never touches .standard")
    func changingPaceLeavesStandardUntouched() {
        let name = "VGNSampleTest-\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: name)!
        defer { isolated.removePersistentDomain(forName: name) }

        let beforePace = UserDefaults.standard.object(forKey: "VGNPlayPaceHours")
        let beforeStyle = UserDefaults.standard.object(forKey: "VGNPlayStyle")

        let prefs = UserDefaultsPlayPacePreferences(defaults: isolated)
        prefs.setPlayPace(PlayPace(hoursPerWeek: 3))
        prefs.setPlayStyle(.completionist)

        // The isolated suite recorded the change…
        #expect(prefs.playStyle() == .completionist)
        #expect(prefs.playPace().hoursPerWeek == 3)
        // …and the owner's real domain is untouched.
        #expect(UserDefaults.standard.object(forKey: "VGNPlayPaceHours") as? Double == beforePace as? Double)
        #expect(UserDefaults.standard.object(forKey: "VGNPlayStyle") as? String == beforeStyle as? String)
    }
}
