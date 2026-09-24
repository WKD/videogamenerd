import SwiftUI

/// The slim explanatory header above the grid when **Needs a "Holds Up" Rating** is selected
/// (PLAN §7b/§8). Mounted like ``BundlesToExpandHeader`` (the outer VStack in `RootView`, never
/// wrapping the grid). Bounded text only (`lineLimit`), never `fixedSize(vertical:)` — the
/// detail column must not leak an ideal height into the split view.
struct HoldsUpRatingHeader: View {
    static let message = "Rate how these play today — a fact about the game now, not a rank."
    static let keysHint = "⌃⌥⌘1 Holds Up · ⌃⌥⌘2 Of Its Time · ⌃⌥⌘3 Too Archaic"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.secondary)
            Text(Self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(Self.keysHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .appKitTooltip("Holds Up — still a great play today. Of Its Time — great then, dated now. "
                       + "Too Archaic — no longer playable for the gamer I am today. Only Play Next "
                       + "uses it; your tiers and duels are untouched.")
        .accessibilityIdentifier("holdsUp.ratingHeader")
    }
}

#if DEBUG
#Preview("Holds Up rating header") {
    HoldsUpRatingHeader().frame(width: 600)
}
#endif
