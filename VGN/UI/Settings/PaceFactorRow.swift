import SwiftUI

/// Settings ▸ General ▸ **Your pace** (PLAN §7b "Scheduled 2026-09-25"): the measured personal
/// pace factor with the number of finished games it rests on (and how many were set aside as
/// incomplete), the per-genre factors with their sample counts (PLAN §7b "Per-genre pace"), and a
/// manual override — a
/// 0.8–2.0 stepper with "Use measured" to go back. Every write goes through the shared
/// ``PlayPaceModel`` (so the shelves, Play Next and Stats re-plan once); nothing is written
/// from `body`.
struct PaceFactorRow: View {
    @Bindable var model: PlayPaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.paceFactorSummary)
                .font(.callout)
                .lineLimit(3)
                .accessibilityIdentifier("settings.paceFactor.summary")
            if let genres = model.genrePaceSummary {
                // Bounded, wrapping inside the Settings pane (not the main window's detail column).
                Text(genres)
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings.paceFactor.genres")
            }
            HStack(spacing: 12) {
                Toggle("Set by hand", isOn: Binding(
                    get: { model.paceOverride != nil },
                    set: { on in
                        model.commitPaceOverride(on ? (model.paceOverride ?? model.measuredPace.measured) : nil)
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.paceFactor.override")
                if let value = model.paceOverride {
                    Stepper(value: Binding(get: { value }, set: { model.commitPaceOverride($0) }),
                            in: PaceFactor.range, step: 0.1) {
                        Text(PaceFactor.text(value)).monospacedDigit()
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    Button("Use measured") { model.commitPaceOverride(nil) }
                        .accessibilityIdentifier("settings.paceFactor.useMeasured")
                }
            }
        }
        .onAppear { model.reload() }
    }
}
