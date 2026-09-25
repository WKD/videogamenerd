import SwiftUI

/// The quiet one-line reminder of what ranking measures (PLAN §7/§7b, owner request wave 22:
/// "when doing duels, remind the philosophy of it vs 'how it holds today'"). Always shown, in a
/// small secondary style — not a dismissable onboarding — with an ⓘ tooltip that expands on it.
///
/// Lives in the main window's DETAIL column (Duel / Triage), so the text is bounded
/// (`lineLimit(2)` + a max width) and never gets `fixedSize(vertical:)` — an unbounded ideal
/// height there pushes the sidebar under the title bar (waves 17 + 19).
struct RankingPhilosophyCaption: View {
    enum Style { case duel, triage }
    var style: Style

    static let duelText = "Which one would you rather keep on your Top list? Memories count here — "
        + "how a game plays today goes in Holds Up."
    static let triageText = "Tiers = your favourites, memories included."
    static let tooltip = "Tiers and duels rank your favourites — nostalgia included: pick the game "
        + "you'd rather keep, however it plays now. \u{201C}Holds up today?\u{201D} is a separate "
        + "fact about playing it NOW (Holds Up · Of Its Time · Too Archaic); only Play Next uses "
        + "it, and it never moves a tier or a rank."

    var text: String { style == .duel ? Self.duelText : Self.triageText }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Image(systemName: "info.circle")
                .imageScale(.small)
                .appKitTooltip(Self.tooltip)
                .accessibilityLabel("About ranking vs Holds Up")
                .accessibilityHint(Self.tooltip)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(style == .duel ? "duel.philosophy" : "triage.philosophy")
    }
}

#if DEBUG
#Preview("Ranking philosophy caption") {
    VStack(spacing: 12) {
        RankingPhilosophyCaption(style: .duel)
        RankingPhilosophyCaption(style: .triage)
    }
    .padding()
}
#endif
