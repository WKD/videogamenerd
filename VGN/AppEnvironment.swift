import Foundation
import SwiftUI

/// The app's composition root (PLAN §8/§9). Built once in ``VGNApp``:
///
/// - opens ``AppDatabase`` (the live on-disk DB, or an in-memory one seeded with
///   the sample library when launched with `-VGNSampleData YES`),
/// - seeds platforms from the bundle and (live only) writes a launch snapshot
///   **off the main actor**, errors logged not fatal,
/// - builds the ``LibraryStore``, the ``GRDBLibraryDataSource``, the
///   ``LibraryViewModel`` and ``LibraryActions``, and the Keychain-backed
///   ``SettingsModel``.
///
/// If the database can't be opened the window shows ``DatabaseErrorView`` instead
/// of crashing. Under the XCTest host nothing is opened (the real file is never
/// touched — tests build their own in-memory stores).
@MainActor
final class AppEnvironment {
    let settings: SettingsModel
    /// The wired-up library view model, or nil when the DB failed to open (or in
    /// the test host).
    let library: LibraryViewModel?
    /// Strong owner of the write-orchestration object (the VM holds it weakly).
    let actions: LibraryActions?
    /// Set when the database could not be opened.
    let failure: DatabaseOpenFailure?

    struct DatabaseOpenFailure: Sendable {
        var message: String
        var path: String
    }

    private init(
        settings: SettingsModel,
        library: LibraryViewModel?,
        actions: LibraryActions?,
        failure: DatabaseOpenFailure?
    ) {
        self.settings = settings
        self.library = library
        self.actions = actions
        self.failure = failure
    }

    /// Build the environment. Never throws — a DB failure becomes `failure`.
    static func launch() -> AppEnvironment {
        let settings = SettingsModel(secretStore: KeychainStore())

        // Never open the real database from the unit-test host.
        if VGNApp.isRunningUnitTests {
            return AppEnvironment(settings: settings, library: nil, actions: nil, failure: nil)
        }

        let mode = LaunchMode.current
        do {
            let database = try mode == .sampleData
                ? AppDatabase.inMemory()
                : AppDatabase.live()
            let store = LibraryStore(database)
            let dataSource = GRDBLibraryDataSource(store: store)
            let vm = LibraryViewModel(dataSource: dataSource, coverLoader: NoopCoverLoader())
            let actions = LibraryActions(store: store, vm: vm)
            actions.install()

            bootstrap(store: store, database: database, mode: mode)

            return AppEnvironment(settings: settings, library: vm, actions: actions, failure: nil)
        } catch {
            let path = (try? AppPaths.databaseURL().path) ?? "~/Library/Application Support/VGN/vgn.sqlite"
            NSLog("VGN: could not open the database: \(error)")
            return AppEnvironment(
                settings: settings, library: nil, actions: nil,
                failure: DatabaseOpenFailure(
                    message: (error as NSError).localizedDescription,
                    path: path
                )
            )
        }
    }

    /// Off-launch-path work: seed platforms, (sample mode) seed the sample
    /// library through the store, and (live mode) write a rotating launch
    /// snapshot off the main actor. All failures are logged, never fatal.
    private static func bootstrap(store: LibraryStore, database: AppDatabase, mode: LaunchMode) {
        Task {
            do { _ = try await database.seedPlatformsFromBundle() }
            catch { NSLog("VGN: platform seed failed: \(error)") }
            if mode == .sampleData {
                await SampleLibrarySeeder.seed(into: store)
            }
        }
        if mode == .live {
            Task.detached(priority: .utility) {
                do { _ = try database.makeLaunchSnapshot() }
                catch { NSLog("VGN: launch snapshot failed: \(error)") }
            }
        }
    }
}

/// How the app was launched. `-VGNSampleData YES` (a process launch argument that
/// `UserDefaults` exposes as the `VGNSampleData` bool) runs against a throwaway
/// in-memory database seeded with the sample library — for demos and UI checks,
/// never touching the real file. Default is the live on-disk database.
enum LaunchMode: Sendable {
    case live
    case sampleData

    static var current: LaunchMode {
        UserDefaults.standard.bool(forKey: "VGNSampleData") ? .sampleData : .live
    }
}
