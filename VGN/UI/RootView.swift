import SwiftUI

/// Placeholder shell. Wave 1 (lane C) replaces this with the real sidebar,
/// grid and inspector. Keep it tiny.
struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Library") {
                    Label("All", systemImage: "square.grid.2x2")
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .navigationTitle("VGN")
        } detail: {
            ContentUnavailableView(
                "No games yet",
                systemImage: "gamecontroller",
                description: Text("Add games in a later milestone.")
            )
        }
    }
}

#if DEBUG
#Preview {
    RootView()
}
#endif
