import SwiftUI

/// The shared PS Plus badge (PLAN §13.3), drawn from the owner-supplied `PSPlusBadge`
/// image asset (wave 17 — replaces the hand-drawn blue "+" in a yellow circle). Used
/// everywhere the marker appears: the grid tile, the inspector copy row, the Vault
/// browser row, the import review sheet. Keeps the asset's aspect ratio inside a square
/// `size` box; a subtle shadow keeps it legible over a cover. Accessibility label
/// "PS Plus".
struct PSPlusBadgeView: View {
    /// The badge's edge length in points (≤ 32 — the asset is downscaled for that).
    var size: CGFloat = 17
    /// A soft shadow so the badge reads over a bright cover; off where the background
    /// already gives contrast (the inspector row, a menu).
    var shadow: Bool = true

    var body: some View {
        Image("PSPlusBadge")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: shadow ? .black.opacity(0.35) : .clear,
                    radius: shadow ? 1 : 0, y: shadow ? 0.5 : 0)
            .accessibilityLabel("PS Plus")
    }
}

#if DEBUG
#Preview("PS Plus badge") {
    HStack(spacing: 12) {
        PSPlusBadgeView(size: 17)
        PSPlusBadgeView(size: 24)
        PSPlusBadgeView(size: 32, shadow: false)
    }
    .padding()
}
#endif
