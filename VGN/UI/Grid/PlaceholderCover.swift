import SwiftUI

/// Generated cover art for games with no artwork yet — which is the entire
/// library on day one (PLAN §5.2 "the library starts with no covers"). Title
/// initials on a stable, per-title tinted gradient, with a faint platform tag.
/// Deterministic, so a game always gets the same tile.
struct PlaceholderCover: View {
    let title: String
    var platformID: String?

    private var initials: String {
        let words = title
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        guard let first = words.first else { return "?" }
        if words.count >= 2, let second = words.dropFirst().first {
            return String(first.prefix(1) + second.prefix(1)).uppercased()
        }
        return String(first.prefix(2)).uppercased()
    }

    private var tint: Color { .stableTint(for: title) }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Text(initials)
                    .font(.system(size: side * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if let platformID {
                    VStack {
                        Spacer()
                        Text(PlatformLabels.short(platformID))
                            .font(.system(size: max(8, side * 0.09), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.bottom, side * 0.06)
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Placeholder covers") {
    HStack(spacing: 12) {
        PlaceholderCover(title: "Bloodborne", platformID: "ps4")
        PlaceholderCover(title: "Metal Gear Solid 3: Snake Eater", platformID: "ps2")
        PlaceholderCover(title: "Ico", platformID: "ps2")
    }
    .frame(height: 200)
    .padding()
}
#endif
