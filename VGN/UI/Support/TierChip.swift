import SwiftUI

/// The tier letter badge (PLAN §8 "tier chip"). Letter on the tier's colour.
/// Hovering any chip shows the tier's label ("S — Masterpiece") as a tooltip; the
/// label comes from `label` when the caller has the `TierInfo`, else from the
/// `\.tierLabels` environment (the live tiers, injected by `RootView`).
struct TierChip: View {
    let letter: String
    var colorHex: String?
    var size: CGFloat = 20
    /// The tier's human label, when the caller has it at hand.
    var label: String? = nil
    /// The game's derived 1–10 score, when the chip stands for a specific game
    /// (grid cell, The Top row, the inspector's current tier). Appended to the
    /// tooltip as "· 9.4" (or "· ~8.5" when approximate). Nil ⇒ label-only text.
    var score: DerivedScoreValue? = nil
    /// False where an enclosing control already carries a richer tooltip.
    var showsLabelOnHover: Bool = true

    @Environment(\.tierLabels) private var tierLabels

    private var color: Color { Color(hex: colorHex) ?? .secondary }

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.62, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .help(showsLabelOnHover
                  ? TierChip.hoverText(letter: letter, label: label, labels: tierLabels, score: score)
                  : "")
    }

    /// "S — Masterpiece" (label-only), or "S — Masterpiece · 9.4" when a game's
    /// derived score is given ("· ~8.5" for an approximate/unplaced score). Falls
    /// back to just the letter's tier name when no label is known.
    static func hoverText(
        letter: String, label: String?, labels: [String: String],
        score: DerivedScoreValue? = nil
    ) -> String {
        let resolved = (label ?? labels[letter.uppercased()])?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = resolved.isEmpty ? "Tier \(letter)" : "\(letter) — \(resolved)"
        guard let score else { return base }
        return "\(base) · \(score.formatted())"
    }
}

extension EnvironmentValues {
    /// Tier letter → label, for `TierChip` tooltips. Defaults to the seeded ladder
    /// (`Migrations.seedTiers`); `RootView` overrides it with the live tiers.
    @Entry var tierLabels: [String: String] = [
        "S": "Masterpiece", "A": "Excellent", "B": "Good",
        "C": "Average", "D": "Bad", "F": "Awful",
    ]
}

/// A small pill for a platform short label ("PS5"), used in chips rows.
struct PlatformChip: View {
    let slug: String

    var body: some View {
        Text(PlatformLabels.short(slug))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

#if DEBUG
#Preview("Chips") {
    VStack(spacing: 12) {
        HStack {
            TierChip(letter: "S", colorHex: "#FF3B30")
            TierChip(letter: "A", colorHex: "#FF9500")
            TierChip(letter: "F", colorHex: "#8E8E93")
        }
        HStack {
            PlatformChip(slug: "ps5")
            PlatformChip(slug: "snes")
            PlatformChip(slug: "pc")
        }
    }
    .padding()
}
#endif
