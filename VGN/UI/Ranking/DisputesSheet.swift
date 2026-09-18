import SwiftUI

/// Lists preference cycles (A>B>C>A) found in the comparison log (PLAN §7 —
/// "disputes to settle"). "Settle" enqueues the cycle's exact pairs (via
/// `RankingStore.enqueuePair`) so the Duel re-asks precisely those comparisons.
struct DisputesSheet: View {
    let disputes: [Consistency.Dispute]
    let titles: [Int64: String]
    var onSettle: (Consistency.Dispute) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Disputes").font(.title2.weight(.semibold))
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if disputes.isEmpty {
                ContentUnavailableView("No disputes", systemImage: "checkmark.circle",
                                       description: Text("No contradictory answers to settle."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List {
                    ForEach(Array(disputes.enumerated()), id: \.offset) { _, dispute in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(cycleText(dispute)).font(.body.monospaced())
                            HStack {
                                Text("^[\(dispute.games.count) game](inflect: true) in the loop")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Settle") { onSettle(dispute) }
                                    .buttonStyle(.borderless)
                                    .help("Duel these exact pairs again to break the cycle")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(width: 460, height: 420)
    }

    private func cycleText(_ dispute: Consistency.Dispute) -> String {
        let names = dispute.cycle.map { titles[$0] ?? "#\($0)" }
        guard let first = names.first else { return "" }
        return (names + [first]).joined(separator: " › ")
    }
}

#if DEBUG
#Preview("Disputes") {
    DisputesSheet(
        disputes: [Consistency.Dispute(games: [1, 2, 3], cycle: [1, 2, 3])],
        titles: [1: "Bloodborne", 2: "Sekiro", 3: "Elden Ring"],
        onSettle: { _ in }, onClose: {}
    )
}
#endif
