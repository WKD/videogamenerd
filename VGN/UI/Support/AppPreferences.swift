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
        else { return .standard }
        let name = "VGNTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name) ?? .standard
        suite.removePersistentDomain(forName: name)
        return suite
    }()
}
