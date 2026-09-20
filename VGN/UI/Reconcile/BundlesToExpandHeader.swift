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
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.secondary)
            Text("These look like bundles imported as one game. Expand one to get its games — "
                 + "IGDB is checked when you click.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5))
    }
}

#if DEBUG
#Preview("Bundles to Expand header") {
    BundlesToExpandHeader().frame(width: 600)
}
#endif
