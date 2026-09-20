import SwiftUI

/// Drives the **Bundles to Expand** list (PLAN §5.1): the library games whose title looks like
/// an unexpanded bundle (``LibraryStore/bundleExpansionCandidates()``), surfaced next to the
/// Unlinked list so the owner can find and expand them. IGDB is queried only when a row is
/// clicked (never in bulk); a game that turns out not to be a bundle is dismissed for good, and
/// a game that expands (or is dismissed) leaves the list on the next reload.
///
/// `@MainActor @Observable`; built over a ``LibraryStore`` (tests use an in-memory DB). The
/// per-row "Expand…" action is delegated so the shared ``IGDBLinkPresenter`` runs the on-demand
/// IGDB check + confirm sheet exactly as the inspector / File-menu action does.
@MainActor
@Observable
final class BundlesToExpandModel {
    private let store: LibraryStore
    /// Opens the on-demand expansion flow for a game (wired to
    /// ``IGDBLinkPresenter/presentBundleExpansion(for:)``); a no-op offline.
    @ObservationIgnored var onExpand: (Int64) -> Void = { _ in }

    private(set) var candidates: [BundleExpansionCandidate] = []
    private(set) var hasLoaded = false

    var count: Int { candidates.count }

    init(store: LibraryStore) { self.store = store }

    /// Reload the candidate list (excludes dismissed "not a bundle" games). Cheap: one query,
    /// no IGDB. Call on appear and whenever the presenter reports a change.
    func reload() {
        Task {
            candidates = (try? await store.bundleExpansionCandidates()) ?? []
            hasLoaded = true
        }
    }

    /// Open the on-demand expansion flow for one candidate (PLAN §5.1).
    func expand(_ candidate: BundleExpansionCandidate) { onExpand(candidate.gameID) }

    /// Persist a "not a bundle" dismissal directly (the row's dismiss affordance), so the game
    /// leaves the list without an IGDB round-trip.
    func dismiss(_ candidate: BundleExpansionCandidate) {
        candidates.removeAll { $0.gameID == candidate.gameID }
        let store = self.store, id = candidate.gameID
        Task { try? await store.dismissBundleCandidate(gameID: id) }
    }
}

/// The Bundles-to-Expand list view (PLAN §5.1). Meant to sit next to the Unlinked list (a
/// segmented switch "Unlinked (N) · Bundles to Expand (N)"); rendered on its own here so it can
/// be mounted wherever the reconcile UI surfaces the two lists.
struct BundlesToExpandView: View {
    @Bindable var model: BundlesToExpandModel

    var body: some View {
        Group {
            if model.candidates.isEmpty {
                ContentUnavailableView(
                    "No bundles to expand", systemImage: "square.stack.3d.up",
                    description: Text("Games whose title looks like a Trilogy / Collection / Pack "
                                      + "show up here so you can expand them into their member games."))
            } else {
                List(model.candidates) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.title)
                            if candidate.igdbID == nil {
                                Text("not linked to IGDB — link it first")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Expand…") { model.expand(candidate) }
                            .controlSize(.small)
                        Button {
                            model.dismiss(candidate)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Not a bundle — remove from this list")
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear { if !model.hasLoaded { model.reload() } }
    }
}
