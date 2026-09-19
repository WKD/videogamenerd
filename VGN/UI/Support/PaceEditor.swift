import SwiftUI

/// The weekly-play-pace editor shared by the sidebar "By Length" header popover and
/// Settings ▸ General (PLAN §8). A coarse slider (1…40 h) plus a stepper that reaches
/// 60 h, a live preview of the five resulting ranges that updates as the draft moves,
/// and "Reset to 8 h". The draft lives here; the model is committed on slider release,
/// on each stepper click, and when the view goes away — never on every drag tick, so
/// the grid/counts do not restart 40 times.
struct PaceEditor: View {
    @Bindable var model: PlayPaceModel
    /// Heading above the controls (the popover asks a question; Settings can pass its
    /// own or hide it with "").
    var title: String = "How much can you play in a typical week?"

    @State private var draft: Double = PlayPace.default.hoursPerWeek

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title).font(.headline)
            }
            Slider(value: $draft, in: 1...40, step: 1) { editing in
                if !editing { model.commit(hoursPerWeek: draft) }   // commit on release, not each tick
            }
            Stepper(value: Binding(get: { draft },
                                   set: { draft = $0; model.commit(hoursPerWeek: $0) }),
                    in: PlayPace.minHours...PlayPace.maxHours, step: 1) {
                Text("\(Int(draft.rounded())) h / week").monospacedDigit()
            }

            Divider()

            // How the owner plays — sets each game's personal length (owner request
            // 2026-09-19). Committing behaves like a pace change (one grid + counts run).
            VStack(alignment: .leading, spacing: 6) {
                Text("How do you play?").font(.subheadline.weight(.semibold))
                Picker("How do you play?", selection: Binding(
                    get: { model.style },
                    set: { model.commitStyle($0) })) {
                    ForEach(PlayStyle.allCases) { style in
                        Text(style.name).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Text(model.style.explanation).font(.caption).foregroundStyle(.secondary)
                Text(model.style.editorExample).font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            // Live preview of the five ranges (pure — no state writes in the body).
            VStack(alignment: .leading, spacing: 5) {
                ForEach(PlayPaceModel.previewRows(forHours: draft), id: \.shelf) { row in
                    HStack(spacing: 8) {
                        Image(systemName: row.shelf.symbol)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(row.shelf.name)
                        Spacer(minLength: 12)
                        Text(row.subtitle).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                }
            }

            HStack {
                Spacer()
                Button("Reset to 8 h") {
                    draft = PlayPace.default.hoursPerWeek
                    model.commit(hoursPerWeek: draft)
                }
                .disabled(draft == PlayPace.default.hoursPerWeek)
            }
        }
        .onAppear { model.reload(); draft = model.pace.hoursPerWeek }
        .onDisappear { model.commit(hoursPerWeek: draft) }
    }
}

/// The small trailing button in the "By Length" section header showing the current
/// pace (or a first-use call to action). Takes an explicit `action` so it is testable
/// with a real click (the popover it opens is view `@State`).
struct PaceHeaderButton: View {
    let label: String
    /// A shorter label used when the full one would not fit (no layout wiggle).
    var compactLabel: String? = nil
    let isCTA: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let compactLabel {
                ViewThatFits(in: .horizontal) {
                    text(label)
                    text(compactLabel)
                }
            } else {
                text(label)
            }
        }
        .buttonStyle(.plain)
        .appKitTooltip("How much you can play in a week and how you play — sets the ranges below")
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(isCTA ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
    }
}

#if DEBUG
#Preview("Pace editor") {
    PaceEditor(model: PlayPaceModel(store: InMemoryPlayPacePreferences(pace: PlayPace(hoursPerWeek: 2), chosen: true)))
        .padding()
        .frame(width: 320)
}
#endif
