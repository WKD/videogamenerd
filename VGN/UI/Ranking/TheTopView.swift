import SwiftUI

/// The Top (PLAN §7, view 2 — numbered #1…#N list, podium for the top 10, tier
/// dividers inline, respects the library filters, CSV / image export).
///
/// STUB — built by the next agent (Tier Board + The Top lane). It replaces this
/// file. Reuse from this folder: ``RankingCoverView``, ``RankingEnvironment``
/// (`ranking.theTop(filter:)` observations give ``TopRow`` with global + derived
/// positions), and the tier chip.
struct TheTopView: View {
    let env: RankingEnvironment
    @State private var rows: [TopRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("The Top", systemImage: "list.number")
                } description: {
                    Text("The numbered chart lands here — built by the next agent.")
                }
            } else {
                List(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.derivedPosition.map { "#\($0)" } ?? "—")
                            .font(.headline.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        if let letter = row.tierLetter {
                            TierChip(letter: letter, colorHex: row.tierColorHex, size: 18)
                        }
                        Text(row.game.title)
                        Spacer()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            rows = (try? await env.ranking.theTopOnce(filter: LibraryFilter(scope: .all, sort: .tierRank))) ?? []
        }
    }
}

#if DEBUG
#Preview("The Top — stub") {
    ContentUnavailableView {
        Label("The Top", systemImage: "list.number")
    } description: {
        Text("Stub — built by the next agent.")
    }
    .frame(width: 700, height: 480)
}
#endif
