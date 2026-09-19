import SwiftUI

/// The merge confirmation model (PLAN §5.1, owner rules 2026-09-19). Shown when the
/// chosen IGDB target is already a library game: the two games merge into one, and this
/// spells out exactly what moves — copies kept, copies collapsed (with a keep-both
/// override where allowed), and the game-detail outcome. `@MainActor @Observable`.
@MainActor
@Observable
final class IGDBMergeModel: Identifiable {
    nonisolated let id = UUID()
    let sourceTitle: String
    let targetTitle: String
    let detailLines: [String]
    let bothRanked: Bool
    private(set) var decisions: [CopyMergeDecision]

    var onConfirm: ([CopyMergeDecision]) -> Void = { _ in }
    var onCancel: () -> Void = {}

    init(inputs: MergeInputs) {
        self.sourceTitle = inputs.sourceTitle
        self.targetTitle = inputs.targetTitle
        self.detailLines = inputs.detailLines
        self.bothRanked = inputs.bothRanked
        self.decisions = inputs.decisions
    }

    /// Copies that move to the target as a distinct copy (rule 1 / rule 3 digital, plus
    /// any collapse the owner overrode to keep both) — grouped under "Moves to …".
    var movingCopies: [CopyMergeDecision] {
        decisions.filter { if case .keep = $0.outcome { return true }; return false }
    }
    /// Copies collapsed into an existing one (rules 2 / 3 physical) — grouped under
    /// "Same copy — merged", with a keep-both toggle where allowed.
    var collapsingCopies: [CopyMergeDecision] {
        decisions.filter { if case .collapse = $0.outcome { return true }; return false }
    }

    func keepBothAllowed(_ decision: CopyMergeDecision) -> Bool {
        if case .collapse(_, let allowed) = decision.outcome { return allowed }
        return false
    }

    func setKeepBoth(_ value: Bool, productID: Int64) {
        guard let i = decisions.firstIndex(where: { $0.sourceProductID == productID }) else { return }
        decisions[i].keepBoth = value
    }

    func copyLabel(_ d: CopyMergeDecision) -> String {
        "\(PlatformLabels.short(d.platformID)) · \(d.format.label) · \(d.source.label)"
    }

    func confirm() { onConfirm(decisions) }
    func cancel() { onCancel() }
}

/// The merge confirmation sheet (PLAN §5.1): three groups — copies that move, copies
/// merged (collapsed), and the game-detail outcome — then one confirm. Undo restores
/// both games exactly.
struct IGDBMergeSheet: View {
    @Bindable var model: IGDBMergeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.movingCopies.isEmpty { movesGroup }
                    if !model.collapsingCopies.isEmpty { mergedGroup }
                    if !model.detailLines.isEmpty { detailsGroup }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Merge into “\(model.targetTitle)”").font(.headline)
            Text("“\(model.sourceTitle)” already exists as \u{201C}\(model.targetTitle)\u{201D}. "
                 + "The two become one game.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var movesGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moves to “\(model.targetTitle)”").font(.subheadline.bold())
            ForEach(model.movingCopies) { d in
                Label(model.copyLabel(d), systemImage: "arrow.right.circle")
                    .font(.callout)
            }
        }
    }

    private var mergedGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Same copy — merged").font(.subheadline.bold())
            ForEach(model.collapsingCopies) { d in
                HStack {
                    Label(model.copyLabel(d), systemImage: "square.on.square.dashed")
                        .font(.callout)
                    Spacer()
                    if model.keepBothAllowed(d) {
                        Toggle("I really own two copies — keep both", isOn: Binding(
                            get: { d.keepBoth },
                            set: { model.setKeepBoth($0, productID: d.sourceProductID) }))
                            .toggleStyle(.checkbox)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var detailsGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Game details").font(.subheadline.bold())
            ForEach(model.detailLines, id: \.self) { line in
                Label(line, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            Button("Merge") { model.confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}
