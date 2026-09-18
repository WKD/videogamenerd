import SwiftUI

/// Tasteful placeholder for the **Play Next** recommendation view (PLAN §7b),
/// reached from the LIBRARY section of the sidebar. The real experience — a
/// time-commitment bracket picker, a hero pick with reasons + match strength,
/// alternatives, and the "Ask Claude" second opinion — is built in a later wave;
/// another agent replaces the contents of exactly this file then.
struct PlayNextPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Play Next", systemImage: "sparkles")
        } description: {
            Text("Pick a time budget and get one game to play from your library — "
                 + "explained. Built in a later wave.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Play Next placeholder") {
    PlayNextPlaceholderView()
        .frame(width: 480, height: 360)
}
#endif
