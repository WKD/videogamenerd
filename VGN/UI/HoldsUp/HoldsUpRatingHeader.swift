import SwiftUI

/// The slim header bar above the grid when **Needs a "Holds Up" Rating** is selected
/// (PLAN §7b/§8). Mounted like ``BundlesToExpandHeader`` (the outer VStack in `RootView`, never
/// wrapping the grid). Bounded text only (`lineLimit`), never `fixedSize(vertical:)` — the
/// detail column must not leak an ideal height into the split view.
///
/// Wave 22 (owner: "the shortcuts are too complex"): three bordered buttons **Holds Up · Of Its
/// Time · Too Archaic** (+ a quiet Clear when the selection carries a mark) act on the grid
/// selection — disabled with no (played) selection — each naming its one-key hint (plain 1/2/3
/// in this list, handled by ``GridKeyRouter``). Rating moves the selection to the next game
/// (``LibraryViewModel/setHoldsUp(_:for:)``). PURE: state in, `onPick` out.
struct HoldsUpRatingHeader: View {
    /// Whether the selection holds at least one played game (the buttons' enabled state).
    var canRate: Bool
    /// Whether some selected game already carries a mark (shows the quiet Clear).
    var showsClear: Bool
    let onPick: (HoldsUp?) -> Void

    static let message = "Rate how these play today — a fact about the game now, not a rank."

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .foregroundStyle(.secondary)
            Text(Self.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            ForEach(HoldsUp.allCases) { value in
                Button {
                    onPick(value)
                } label: {
                    HStack(spacing: 5) {
                        Text(value.label).lineLimit(1)
                        Text(GridKeyRouter.holdsUpHint(for: value, inHoldsUpList: true))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canRate)
                .appKitTooltip(value.explanation + "  (key: "
                               + GridKeyRouter.holdsUpHint(for: value, inHoldsUpList: true) + ")")
                .accessibilityIdentifier("holdsUp.header.\(value.rawValue)")
            }
            if showsClear {
                Button {
                    onPick(nil)
                } label: {
                    Text("Clear").lineLimit(1).fixedSize()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
                .disabled(!canRate)
                .appKitTooltip("Clear — back to Unrated  (key: 0 — in this list 0 clears the "
                               + "Holds Up mark, not the tier)")
                .accessibilityIdentifier("holdsUp.header.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        .accessibilityIdentifier("holdsUp.ratingHeader")
    }
}

#if DEBUG
#Preview("Holds Up rating header") {
    HoldsUpRatingHeader(canRate: true, showsClear: true) { _ in }.frame(width: 700)
}
#endif
