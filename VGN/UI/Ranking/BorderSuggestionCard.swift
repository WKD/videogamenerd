import SwiftUI

/// The card a border duel produces (PLAN §7 — "Promote X to S?" / "Demote Y to
/// A?" with Accept / Dismiss, keys `↩` / `esc`). Never moves a game on its own;
/// the store applies only on Accept.
struct BorderSuggestionCard: View {
    let suggestion: BorderSuggestion
    var candidate: DuelSide?
    var opponent: DuelSide?
    var tier: (Int64) -> TierInfo?
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var movedTitle: String {
        if candidate?.id == suggestion.game { return candidate?.title ?? "This game" }
        if opponent?.id == suggestion.game { return opponent?.title ?? "This game" }
        return "This game"
    }

    private var toTier: TierInfo? { tier(suggestion.toTier) }

    private var verb: String { suggestion.kind == .promote ? "Promote" : "Demote" }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: suggestion.kind == .promote ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(suggestion.kind == .promote ? .green : .orange)

                VStack(spacing: 6) {
                    Text("\(verb) \(movedTitle)?").font(.title2.weight(.semibold))
                    if let toTier {
                        HStack(spacing: 8) {
                            Text("Move to")
                            TierChip(letter: toTier.letter, colorHex: toTier.colorHex, size: 22,
                                     label: toTier.label)
                            Text(toTier.label)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 12) {
                    Button(role: .cancel) { onDismiss() } label: {
                        Text("Dismiss").frame(minWidth: 90)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button { onAccept() } label: {
                        Text("Accept").frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

                Text("↩ accept · esc dismiss")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            .shadow(radius: 20, y: 6)
        }
    }
}

#if DEBUG
#Preview("Border card — promote") {
    BorderSuggestionCard(
        suggestion: BorderSuggestion(game: 2, fromTier: 2, toTier: 1, kind: .promote),
        candidate: DuelSide(id: 1, title: "Elden Ring", tierLetter: "S"),
        opponent: DuelSide(id: 2, title: "Sekiro", tierLetter: "A"),
        tier: { TierInfo.defaultTier(forLetter: $0 == 1 ? "S" : "A") },
        onAccept: {}, onDismiss: {}
    )
    .frame(width: 820, height: 620)
}
#endif
