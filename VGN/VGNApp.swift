import SwiftUI

@main
struct VGNApp: App {
    @State private var library: LibraryViewModel
    @State private var settings: SettingsModel

    init() {
        let secretStore: any SecretStoring = KeychainStore()
        _settings = State(initialValue: SettingsModel(secretStore: secretStore))
        _library = State(initialValue: VGNApp.makeLibraryViewModel())
    }

    var body: some Scene {
        WindowGroup {
            // When hosted by the XCTest runner, render a trivial view: the full
            // window (async observations + toolbar/inspector) otherwise starves
            // the runner's launch handshake and it "hangs before establishing
            // connection". Unit tests exercise the view model directly, not the
            // window, so this costs no coverage. Harmless in the real app.
            if VGNApp.isRunningUnitTests {
                Color.clear
            } else {
                RootView(vm: library)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { LibraryCommands() }

        Settings {
            SettingsView(model: settings)
        }
    }

    /// True when the process is a unit-test host (set by XCTest at launch).
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Build the window's view model.
    ///
    /// TEMPORARY (Wave 1): there is no database on this branch yet, so in DEBUG
    /// the shell runs against sample data through `PreviewLibraryDataSource`.
    /// The switch below is the single, clearly-named place to remove next wave:
    /// replace the data source with the GRDB-backed `LibraryDataSource` once the
    /// database lane has merged. The cover loader likewise swaps `NoopCoverLoader`
    /// for the services lane's `CoverStore`.
    static func makeLibraryViewModel() -> LibraryViewModel {
        #if DEBUG
        if usePreviewDataUntilLiveWiring {
            return LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        }
        #endif
        return LibraryViewModel(dataSource: PreviewLibraryDataSource.empty)
    }

    #if DEBUG
    /// Flip to `false` to preview the empty-library state in DEBUG. Remove the
    /// whole switch when live wiring lands.
    static let usePreviewDataUntilLiveWiring = true
    #endif
}

// MARK: - Menu commands (PLAN §8)

/// Reaches the focused window's view model through `@FocusedValue`.
struct LibraryCommands: Commands {
    @FocusedValue(\.library) private var library

    var body: some Commands {
        // ⌘N Quick Add — posts the intent only; the palette is another lane.
        CommandGroup(replacing: .newItem) {
            Button("Quick Add…") { library?.requestQuickAdd() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(library == nil)
        }

        // View menu: inspector toggle, focus search, smart-list navigation.
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { library?.toggleInspector() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(library == nil)

            Button("Find") { library?.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(library == nil)

            Divider()

            Button("All Games") { library?.select(.all) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Owned") { library?.select(.owned) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Played") { library?.select(.played) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Backlog") { library?.select(.backlog) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Unranked") { library?.select(.unranked) }
                .keyboardShortcut("5", modifiers: .command)

            Divider()

            Button("Tier Board") { library?.select(.tierBoard) }
            Button("The Top") { library?.select(.theTop) }
            Button("Duel") { library?.select(.duel) }
        }
    }
}

// MARK: - Focused value seam

/// Carries the focused window's `LibraryViewModel` to the scene `Commands`.
struct LibraryFocusedValueKey: FocusedValueKey {
    typealias Value = LibraryViewModel
}

extension FocusedValues {
    var library: LibraryViewModel? {
        get { self[LibraryFocusedValueKey.self] }
        set { self[LibraryFocusedValueKey.self] = newValue }
    }
}
