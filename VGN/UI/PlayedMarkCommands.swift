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
    @FocusedValue(\.hltbFetchPresenter) private var hltb

    var body: some Commands {
        CommandMenu("Game") {
            let enabled = library?.canMarkSelectionPlayed ?? false
            let last = library?.lastPlayedMark ?? .played
            // The selection's already-loaded summaries drive every mixed-state mark: ✓ (all)
            // / – (mixed) / nothing (none), same computation as the grid context menu (wave 17).
            let selection = library?.selectedGames ?? []

            StateMenuButton(title: "\(last.menuTitle)   ⇧M",
                            state: selection.playedMarkState(last)) { library?.applyLastPlayedMark() }
                .disabled(!enabled)

            Menu("Mark Played As") {
                ForEach(PlayedMark.allCases) { mark in
                    StateMenuButton(title: mark.label, state: selection.playedMarkState(mark)) {
                        guard let library else { return }
                        library.markPlayed(library.selectedGameIDs, as: mark)
                    }
                    .disabled(!enabled)
                }
            }
            .disabled(!enabled)

            // Change Copy Format ▸ Physical / Digital / ROM (PLAN §13.3). Acts on the
            // selection's single-copy games; several-copy games are skipped (banner + footer).
            let canFormat = library?.canChangeSelectionCopyFormat ?? false
            Menu("Change Copy Format") {
                ForEach(ProductFormat.allCases, id: \.self) { format in
                    StateMenuButton(title: format.label, state: selection.copyFormatState(format)) {
                        library?.changeCopyFormat(to: format)
                    }
                    .disabled(!canFormat)
                }
                let several = selection.severalCopiesCount
                if several > 0 {
                    Divider()
                    Button { } label: { Text("^[\(several) game](inflect: true) with several copies not changed") }
                        .disabled(true)
                }
            }
            .disabled(!canFormat)

            Divider()

            // HowLongToBeat gap-fill (PLAN §5.3): the current selection, or the whole
            // library when nothing is selected.
            Button("Fetch Missing Time Estimates…") { hltb?.presentBulk() }
                .disabled(!(hltb?.canRunBulk ?? false))
                .help("Fill missing time-to-beat estimates from HowLongToBeat for the "
                      + "current selection, or every game with no estimate.")
            // HowLongToBeat replace (PLAN §5.3): overwrite the three estimates for the
            // selection (typically the filtered suspicious ones), or every flagged game.
            Button("Refresh Time Estimates from HowLongToBeat…") { hltb?.presentRefresh() }
                .disabled(!(hltb?.canRunBulk ?? false))
                .help("Replace the rushed / main / completionist estimates from HowLongToBeat for "
                      + "the current selection, or every game with a suspicious estimate. Values are overwritten.")
            // Manual search + link for one game (PLAN §5.3, D5) — useful for long / edition-heavy titles.
            Button("Find on HowLongToBeat…") { hltb?.findSelected() }
                .disabled(!(hltb?.canFindSelected ?? false))
                .help("Search HowLongToBeat by title and link the selected game to its entry.")
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
