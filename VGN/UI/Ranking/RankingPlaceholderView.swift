import SwiftUI

/// Tasteful placeholder for the ranking destinations until milestone 4 builds
/// them (PLAN §7, §10). Tier Board / The Top / Duel each land in a later wave.
struct RankingPlaceholderView: View {
    let selection: SidebarSelection

    private var title: String { SidebarView.title(for: selection) }
    private var icon: String { SidebarView.icon(for: selection) }

    private var subtitle: String {
        switch selection {
        case .tierBoard: return "Tier Board — coming in milestone 4"
        case .theTop: return "The Top — coming in milestone 4"
        case .duel: return "Duel — coming in milestone 4"
        default: return "Coming soon"
        }
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(subtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Ranking placeholder") {
    RankingPlaceholderView(selection: .tierBoard)
        .frame(width: 480, height: 360)
}
#endif
