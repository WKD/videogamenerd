import Foundation

/// Where persisted UI preferences live. In the app that is `UserDefaults.standard`.
/// Under the unit-test host it is a throw-away suite: the tests run *inside* the app, so
/// `.standard` would be the owner's real preferences — a sort order chosen in the app made
/// three view-model tests fail on 2026-09-19. Launch arguments (`-VGNSampleData` …) are
/// still read from `.standard`, which is where the argument domain lives.
enum AppPreferences {
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        else {
            // A profile (`-VGNProfile <name>`) keeps its own preferences, so e.g. arming
            // PSN in a test profile never arms it in the real one.
            guard let profile = AppProfile.name else { return .standard }
            let bundleID = Bundle.main.bundleIdentifier ?? "com.pomatelier.VideoGameNerd"
            return UserDefaults(suiteName: AppProfile.defaultsSuiteName(bundleID: bundleID, profile: profile)) ?? .standard
        }
        let name = "VGNTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }()
}
