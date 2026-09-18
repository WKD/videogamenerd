import SwiftUI

/// Tier Board (PLAN §7, view 1 — classic tier-list rows, drag between rows to
/// change tier, drag within a row for fine order, dimmed unplaced tail).
///
/// STUB — built by the next agent (Tier Board + The Top lane). It replaces this
/// file. Reuse from this folder: ``RankingCoverView`` (aspect-fit cover on a
/// neutral backing), ``RankingTierLegend`` (the six coloured keys),
/// ``RankingEnvironment`` (`ranking` / `library` / `coverLoader`, plus
/// `ranking.tierBoard()` observations).
struct TierBoardView: View {
    let env: RankingEnvironment
    @State private var rows: [TierBoardRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("Tier Board", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Tier-list rows land here — built by the next agent.")
                }
            } else {
                List(rows) { row in
                    Section {
                        Text("^[\(row.total) game](inflect: true)")
                            .font(.caption).foregroundStyle(.secondary)
                    } header: {
                        HStack(spacing: 8) {
                            TierChip(letter: row.tier.letter, colorHex: row.tier.colorHex, size: 22)
                            Text(row.tier.label)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            rows = (try? await env.ranking.tierBoardOnce()) ?? []
        }
    }
}

#if DEBUG
#Preview("Tier Board — stub") {
    ContentUnavailableView {
        Label("Tier Board", systemImage: "square.stack.3d.up")
    } description: {
        Text("Stub — built by the next agent.")
    }
    .frame(width: 700, height: 480)
}
#endif
