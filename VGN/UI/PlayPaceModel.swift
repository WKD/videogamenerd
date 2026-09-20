import SwiftUI
import Observation

/// The shared, observable weekly-play-pace controller behind the "By Length" section
/// header popover **and** the Settings ▸ General pane (PLAN §8). Both hold a model
/// over the *same* ``PlayPacePreferenceStoring``, so a change in one shows up in the
/// other on its next open (`reload`). Writes happen only in control actions.
@MainActor
@Observable
final class PlayPaceModel {
    private let store: any PlayPacePreferenceStoring

    /// The committed pace (persisted). The live popover preview uses a *draft* held
    /// in the view; only `commit`/`reset` change this.
    private(set) var pace: PlayPace
    /// Whether the owner has ever chosen a pace (drives the first-use CTA label).
    private(set) var hasChosen: Bool
    /// The committed play style (persisted), which sets each game's personal length.
    private(set) var style: PlayStyle

    /// Invoked with the committed pace after `commit`/`reset`. The app wires this so a
    /// pace change re-runs the grid + counts (treated like a filter change).
    var onCommit: (PlayPace) -> Void = { _ in }
    /// Invoked with the committed style after `commitStyle`. Wired like ``onCommit`` so
    /// a style change re-runs the grid + counts once (owner request 2026-09-19).
    var onStyleCommit: (PlayStyle) -> Void = { _ in }

    init(store: any PlayPacePreferenceStoring) {
        self.store = store
        self.pace = store.playPace()
        self.hasChosen = store.hasChosenPace()
        self.style = store.playStyle()
    }

    /// Re-read from the store — call when a popover/pane appears so a change made in
    /// the other place is reflected.
    func reload() {
        pace = store.playPace()
        hasChosen = store.hasChosenPace()
        style = store.playStyle()
    }

    /// Commit a new play style, persist, notify (so the grid + counts re-run once).
    func commitStyle(_ newStyle: PlayStyle) {
        guard newStyle != style else { return }
        store.setPlayStyle(newStyle)
        style = newStyle
        onStyleCommit(newStyle)
    }

    /// Commit a new pace (clamped by ``PlayPace``), persist, mark chosen, notify.
    /// A no-op body still notifies so callers can rely on it.
    func commit(hoursPerWeek: Double) {
        let new = PlayPace(hoursPerWeek: hoursPerWeek)
        store.setPlayPace(new)
        pace = new
        hasChosen = true
        onCommit(new)
    }

    /// "Reset to 8 h".
    func reset() { commit(hoursPerWeek: PlayPace.default.hoursPerWeek) }

    /// The five shelves' ranges for any *draft* pace, for the live preview (pure).
    static func previewRows(forHours hours: Double) -> [(shelf: LengthShelf, subtitle: String)] {
        let bounds = LengthShelf.bounds(for: PlayPace(hoursPerWeek: hours))
        return LengthShelf.allCases.map { ($0, $0.subtitle(bounds: bounds)) }
    }

    /// The compact header label, e.g. "8 h / week" (or the first-use call to action).
    var headerLabel: String {
        hasChosen ? "\(LengthShelf.formatHours(pace.hoursPerWeek)) h / week" : "Set your pace…"
    }

    /// The wider header label including the play style, e.g. "8 h / week · lots of side
    /// quests" — shown when it fits, else the compact ``headerLabel`` (no layout wiggle).
    var headerLabelWithStyle: String {
        hasChosen ? "\(headerLabel) · \(style.name.lowercased())" : headerLabel
    }

    /// The play style, moved out of the (too-long) section title into the header tooltip
    /// (owner request, wave 17): "8 h / week · playing lots of side quests — click to change".
    var styleTooltip: String {
        hasChosen
            ? "\(headerLabel) · playing \(style.name.lowercased()) — click to change your pace and play style"
            : "Set how much you can play in a week and how you play — sets the ranges below"
    }
}
