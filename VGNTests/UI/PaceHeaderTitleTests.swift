import Testing
@testable import VGN

/// The BY LENGTH sidebar title shows only the pace; the play style moved to the tooltip
/// (owner request, wave 17 — D4).
@MainActor
struct PaceHeaderTitleTests {
    @Test func headerLabelIsPaceOnlyStyleInTooltip() {
        let model = PlayPaceModel(store: InMemoryPlayPacePreferences(
            pace: PlayPace(hoursPerWeek: 6), chosen: true))
        // The section title shows only the pace — no play style.
        #expect(model.headerLabel == "6 h / week")
        #expect(!model.headerLabel.lowercased().contains(model.style.name.lowercased()))
        // The style lives in the tooltip now.
        #expect(model.styleTooltip.contains("6 h / week"))
        #expect(model.styleTooltip.lowercased().contains(model.style.name.lowercased()))
    }

    @Test func firstUseTooltipPromptsToSetPace() {
        let model = PlayPaceModel(store: InMemoryPlayPacePreferences(
            pace: PlayPace(hoursPerWeek: 8), chosen: false))
        #expect(model.headerLabel == "Set your pace…")
        #expect(model.styleTooltip.lowercased().contains("how much"))
    }
}
