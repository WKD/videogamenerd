import SwiftUI

@main
struct VGNApp: App {
    @State private var env: AppEnvironment

    init() {
        _env = State(initialValue: AppEnvironment.launch())
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
            } else if let library = env.library {
                RootView(vm: library)
                    .frame(minWidth: 900, minHeight: 600)
            } else if let failure = env.failure {
                DatabaseErrorView(failure: failure)
            } else {
                Color.clear
            }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { LibraryCommands() }

        Settings {
            SettingsView(model: env.settings)
        }
    }

    /// True when the process is a unit-test host (set by XCTest at launch).
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
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
