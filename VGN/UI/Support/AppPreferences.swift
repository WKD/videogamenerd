import Foundation

/// Where persisted UI preferences live (pace, play style, PS Plus deadline, sort order…).
/// In the real app that is `UserDefaults.standard`.
///
/// It is a throw-away suite instead whenever preferences must NOT reach the owner's real
/// domain:
///  - the unit-test host — the tests run *inside* the app, so `.standard` would be the
///    owner's real preferences (a sort order chosen in the app made three view-model tests
///    fail on 2026-09-19);
///  - a `-VGNSampleData` / `-VGNSeedGames` launch — a demo / perf run must never write the
///    owner's real pace, play style, PS Plus deadline or sort order (owner request
///    2026-09-20: "in sample mode the play pace setting writes to your real preferences").
///
/// Launch arguments are still read from `.standard`, which is where the argument domain
/// lives — the same way ``LaunchMode`` reads them.
enum AppPreferences {
    nonisolated(unsafe) static let defaults: UserDefaults = makeDefaults()

    /// Whether preferences must be isolated for this launch (see the type doc).
    static var isIsolatedLaunch: Bool {
        let isTestHost = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let d = UserDefaults.standard
        return wantsIsolatedDefaults(
            isTestHost: isTestHost,
            sampleData: d.bool(forKey: "VGNSampleData"),
            seedGames: d.integer(forKey: "VGNSeedGames"))
    }

    /// The pure decision: isolate when running under the test host or in a throwaway
    /// (sample / seeded) launch mode. Split out so it is unit-testable without the launch.
    static func wantsIsolatedDefaults(isTestHost: Bool, sampleData: Bool, seedGames: Int) -> Bool {
        isTestHost || sampleData || seedGames > 0
    }

    private static func makeDefaults() -> UserDefaults {
        if isIsolatedLaunch {
            let name = "VGNTests-\(UUID().uuidString)"
            let suite = UserDefaults(suiteName: name) ?? .standard
            suite.removePersistentDomain(forName: name)
            return suite
        }
        // A profile (`-VGNProfile <name>`) keeps its own preferences, so e.g. arming
        // PSN in a test profile never arms it in the real one.
        guard let profile = AppProfile.name else { return .standard }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pomatelier.VideoGameNerd"
        return UserDefaults(suiteName: AppProfile.defaultsSuiteName(bundleID: bundleID, profile: profile)) ?? .standard
    }
}
