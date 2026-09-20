import SwiftUI

/// The slim explanatory header shown above the grid when the "Bundles to Expand" smart list is
/// selected (PLAN §5.1 / §8). The list itself is now a sidebar smart list rendered in the normal
/// grid (decision, wave 16: consistency with Unlinked beats a separate panel), scoped to the
/// candidate ids by ``LibraryStore/fetchBundleExpansionCandidates(_:)``. The per-game
/// "Expand Bundle into Games…" action lives in the grid context menu, the inspector and the
/// File menu, all routing to ``IGDBLinkPresenter/presentBundleExpansion(for:)``.
///
/// (The old, never-mounted `BundlesToExpandModel` / `BundlesToExpandView` were removed with this
/// change — no dead code; the id provider is the store's shared candidate rule.)
struct BundlesToExpandHeader: View {
    @Bindable var vm: LibraryViewModel
    /// Unplayed-candidate count for the "Expand All Unplayed (N)…" button; loaded from the store
    /// and refreshed whenever the total candidate count changes (after an expansion).
    @State private var unplayedCount = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.secondary)
            Text("These look like bundles imported as one game. Expand one to get its games — "
                 + "IGDB is checked when you click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if unplayedCount > 0 {
                // Expand every candidate with no play data in one pass (PLAN §13.3 / §5.1 D4b).
                Button("Expand All Unplayed (\(unplayedCount))…") { vm.onExpandAllUnplayedBundles() }
                    .controlSize(.small)
                    .accessibilityIdentifier("bundles.expandAllUnplayed")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
        // Reload the unplayed count on appear and whenever the live candidate count changes
        // (an expansion removes candidates, so the button count drops or the button disappears).
        .task(id: vm.counts.bundlesToExpand) { unplayedCount = await vm.loadUnplayedBundleCount() }
    }
}

#if DEBUG
#Preview("Bundles to Expand header") {
    BundlesToExpandHeader(vm: LibraryViewModel(dataSource: PreviewLibraryDataSource.large))
        .frame(width: 600)
}
#endif
