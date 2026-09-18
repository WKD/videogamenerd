import SwiftUI

/// Shown when the duel queue is drained (PLAN §7): per-tier stats, a Refine
/// button (re-checks for refine pairs), the pointer to Triage when there are
/// unranked played games, and the disputes chip.
struct DuelEmptyStateView: View {
    @Bindable var model: DuelModel
    /// The dispatcher sets this to switch to the Triage tab.
    var onGoToTriage: () -> Void = {}
    var onOpenDisputes: () -> Void = {}

    var body: some View {
        content.accessibilityIdentifier(A11yID.duelEmpty)
    }

    private var content: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("All caught up").font(.title2.weight(.semibold))
            Text("Every played, tiered game has its exact spot.")
                .font(.callout).foregroundStyle(.secondary)

            statsRow

            HStack(spacing: 12) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refine", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Look for neighbour pairs to double-check")

                if model.unrankedCount > 0 {
                    Button {
                        onGoToTriage()
                    } label: {
                        Label("Triage \(model.unrankedCount) unranked", systemImage: "tray.full")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !model.disputes.isEmpty {
                    Button {
                        onOpenDisputes()
                    } label: {
                        Label("\(model.disputes.count) disputes", systemImage: "exclamationmark.triangle")
                    }
                    .tint(.orange)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statsRow: some View {
        HStack(spacing: 14) {
            ForEach(model.stats.perTier) { tier in
                VStack(spacing: 4) {
                    TierChip(letter: tier.letter, colorHex: model.tier(tier.tierID)?.colorHex, size: 28)
                    Text("\(tier.placed)")
                        .font(.headline.monospacedDigit())
                    if tier.unplaced > 0 {
                        Text("+\(tier.unplaced)")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}

#if DEBUG
#Preview("Duel — empty state") {
    let model = DuelModel(backend: ScriptedRankingBackend.previewEmpty())
    return DuelEmptyStateView(model: model)
        .frame(width: 640, height: 480)
        .task { await model.start() }
}
#endif
