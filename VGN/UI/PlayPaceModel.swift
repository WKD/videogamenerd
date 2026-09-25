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

    /// The measured personal pace factor (PLAN §7b "Scheduled 2026-09-25"): fed from the
    /// library by the owner of this model (``LibraryViewModel`` observes it); ``PaceFactor/unmeasured``
    /// until the first read. Never persisted.
    private(set) var measuredPace: PaceFactor = .unmeasured
    /// The owner's manual override (persisted), or nil to use the measured factor.
    private(set) var paceOverride: Double?
    /// The factor(s) everything plans with: the override (one number), else the measured global
    /// + per-genre factors (PLAN §7b "Per-genre pace").
    var paceFactor: PaceProfile { measuredPace.effective(override: paceOverride) }

    /// Invoked with the new effective pace factor whenever it changes (a new measurement or
    /// an override edit). Wired like ``onStyleCommit`` so the grid + counts re-run once.
    var onPaceFactorChange: (PaceProfile) -> Void = { _ in }

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
        self.paceOverride = store.paceFactorOverride()
    }

    /// Re-read from the store — call when a popover/pane appears so a change made in
    /// the other place is reflected.
    func reload() {
        pace = store.playPace()
        hasChosen = store.hasChosenPace()
        style = store.playStyle()
        let before = paceFactor
        paceOverride = store.paceFactorOverride()
        if paceFactor != before { paceFactorChanged() }
    }

    // MARK: Pace factor

    /// Adopt a fresh measurement (from the library observation). Notifies only when the
    /// effective factor moves (an override hides measurement churn).
    func setMeasuredPace(_ measured: PaceFactor) {
        guard measured != measuredPace else { return }
        let before = paceFactor
        measuredPace = measured
        if paceFactor != before { paceFactorChanged() }
    }

    /// Set (a value, clamped to ``PaceFactor/range``, rounded to 0.1) or clear (nil — "Use measured") the
    /// manual override, persist it, and notify when the effective factor moves.
    func commitPaceOverride(_ value: Double?) {
        // One decimal, like the display ("1.3×") — so stepper steps never accumulate 1.2000000001.
        let clamped = value.map { (PaceFactor.clamp($0) * 10).rounded() / 10 }
        guard clamped != paceOverride else { return }
        let before = paceFactor
        store.setPaceFactorOverride(clamped)
        paceOverride = clamped
        if paceFactor != before { paceFactorChanged() }
    }

    private func paceFactorChanged() {
        onPaceFactorChange(paceFactor)
        NotificationCenter.default.post(name: .vgnPaceFactorDidChange, object: nil)
    }

    /// The Settings sentence: "You take about 1.3× the advertised time · based on 109
    /// finished games", or why there is no measurement yet.
    var paceFactorSummary: String {
        Self.paceFactorSummary(measured: measuredPace, override: paceOverride)
    }

    nonisolated static func paceFactorSummary(measured: PaceFactor, override: Double?) -> String {
        let games = measured.sampleCount == 1 ? "finished game" : "finished games"
        if let override {
            // The override replaces the genre factors too — one number for every game.
            let base = measured.isMeasured
                ? "measured \(PaceFactor.text(measured.measured)) on \(measured.sampleCount) \(games)"
                : "not enough finished games to measure yet"
            return "You plan with \(PaceFactor.text(override)) the advertised time (set by hand · \(base))"
        }
        guard measured.isMeasured else {
            let more = PaceFactor.minSamples - measured.sampleCount
            return "Planning with the advertised times (1.0×) · finish \(more) more game\(more == 1 ? "" : "s") with a play time and an estimate to measure your pace"
        }
        let aside = measured.setAsideCount > 0
            ? " (\(measured.setAsideCount) set aside as incomplete)" : ""
        return "You take about \(PaceFactor.text(measured.measured)) the advertised time · based on \(measured.sampleCount) \(games)\(aside)"
    }

    /// Settings' per-genre line (PLAN §7b "Per-genre pace"), or nil when no genre qualifies or the
    /// manual override replaces everything.
    var genrePaceSummary: String? {
        Self.genrePaceSummary(measured: measuredPace, override: paceOverride)
    }

    nonisolated static func genrePaceSummary(measured: PaceFactor, override: Double?) -> String? {
        guard override == nil, measured.isMeasured else { return nil }
        return measured.genreSummary.map { "By genre: \($0)" }
    }

    /// Commit a new play style, persist, notify (so the grid + counts re-run once, and any
    /// other open window — the Library Stats window — re-reads it via ``Notification/Name/vgnPlayStyleDidChange``).
    func commitStyle(_ newStyle: PlayStyle) {
        guard newStyle != style else { return }
        store.setPlayStyle(newStyle)
        style = newStyle
        onStyleCommit(newStyle)
        NotificationCenter.default.post(name: .vgnPlayStyleDidChange, object: nil)
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

extension Notification.Name {
    /// Posted when the effective personal pace factor changes (new measurement or override).
    /// Other windows (Library Stats) re-read and re-query, like ``vgnPlayStyleDidChange``.
    static let vgnPaceFactorDidChange = Notification.Name("vgn.paceFactorDidChange")
}
