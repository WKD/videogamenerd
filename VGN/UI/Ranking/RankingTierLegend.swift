import SwiftUI

/// The six coloured tier keys, always visible during Triage (PLAN §7 — "Tier
/// legend with the six coloured keys always visible; clicking a key works too").
/// Reusable by the Tier Board / The Top lane. Tapping a key invokes `onPick`.
struct RankingTierLegend: View {
    let tiers: [TierInfo]
    /// Currently highlighted tier (e.g. the last one applied), or nil.
    var highlighted: Int64?
    var onPick: (TierInfo) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tiers) { tier in
                Button {
                    onPick(tier)
                } label: {
                    VStack(spacing: 4) {
                        TierChip(letter: tier.letter, colorHex: tier.colorHex, size: 34)
                        Text(tier.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(highlighted == tier.id ? Color(hex: tier.colorHex)?.opacity(0.18) ?? .clear : .clear)
                    )
                }
                .buttonStyle(.plain)
                .help("Tier \(tier.letter) — \(tier.label)  (press \(tier.letter))")
            }
        }
    }
}

#if DEBUG
#Preview("Tier legend") {
    RankingTierLegend(tiers: TierInfo.defaults, highlighted: 2) { _ in }
        .padding()
}

extension TierInfo {
    /// The default S A B C D F tiers (matches the DB seed) for previews/tests.
    static let defaults: [TierInfo] = [
        TierInfo(id: 1, letter: "S", label: "Masterpiece", colorHex: "#FF7F7F", sort: 0),
        TierInfo(id: 2, letter: "A", label: "Excellent", colorHex: "#FFBF7F", sort: 1),
        TierInfo(id: 3, letter: "B", label: "Good", colorHex: "#FFDF7F", sort: 2),
        TierInfo(id: 4, letter: "C", label: "Average", colorHex: "#FFFF7F", sort: 3),
        TierInfo(id: 5, letter: "D", label: "Bad", colorHex: "#BFFF7F", sort: 4),
        TierInfo(id: 6, letter: "F", label: "Awful", colorHex: "#7FFF7F", sort: 5),
    ]

    /// Look up a default tier by its letter (Triage key handling in previews).
    static func defaultTier(forLetter letter: String) -> TierInfo? {
        defaults.first { $0.letter == letter.uppercased() }
    }
}
#endif
