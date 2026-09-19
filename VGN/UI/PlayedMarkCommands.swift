import SwiftUI

/// Menu-bar "Game ▸ Mark Played" commands (PLAN §8, owner request 2026-09-19):
/// a top-level item that repeats the last-chosen mark and a "Mark Played As"
/// submenu. Both act on the focused window's selection and are enabled only when
/// a library grid destination has a non-empty selection.
///
/// The repeat item carries no key equivalent: a shift-only equivalent (⇧M) would
/// steal a capital "M" typed in the search field / Quick Add, so ⇧M is shown as a
/// title hint and the key itself is handled by the grid router. This builder is
/// **pure** — it only reads the view model; every write is inside a Button action.
struct PlayedMarkCommands: Commands {
    @FocusedValue(\.library) private var library

    var body: some Commands {
        CommandMenu("Game") {
            let enabled = library?.canMarkSelectionPlayed ?? false
            let last = library?.lastPlayedMark ?? .played

            Button("\(last.menuTitle)   ⇧M") { library?.applyLastPlayedMark() }
                .disabled(!enabled)

            Menu("Mark Played As") {
                ForEach(PlayedMark.allCases) { mark in
                    Button {
                        guard let library else { return }
                        library.markPlayed(library.selectedGameIDs, as: mark)
                    } label: {
                        if mark == last { Label(mark.label, systemImage: "checkmark") }
                        else { Text(mark.label) }
                    }
                    .disabled(!enabled)
                }
            }
            .disabled(!enabled)
        }
    }
}

extension LibraryViewModel {
    /// Whether the menu-bar "Mark Played" commands should be enabled: a non-empty
    /// selection in a library grid destination.
    var canMarkSelectionPlayed: Bool {
        !selectedGameIDs.isEmpty && isLibraryGridDestination
    }
}
