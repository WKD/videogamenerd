import SwiftUI

/// One action offered by an ``EmptyStateView`` (up to two per state). Wired to an EXISTING
/// command / callback — an empty state never invents navigation. When no callback exists the
/// state shows its sentence with no button (owner 2026-09-20).
struct EmptyStateAction: Identifiable {
    let title: String
    var systemImage: String? = nil
    var isProminent: Bool = false
    var accessibilityID: String? = nil
    let action: () -> Void

    var id: String { title }
}

/// The shared "richer empty state" (PLAN §10, milestone 9): an SF Symbol, a short title, one
/// second-person sentence, and up to two action buttons. Purely static — no timers or
/// animation — so it costs nothing at idle and needs no Reduce Motion handling. Centred in
/// whatever space it is given, with a capped text width so long messages stay readable.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actions: [EmptyStateAction] = []
    var accessibilityID: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // Bounded, NOT `.fixedSize(vertical: true)`: this view is mounted in the
                    // `NavigationSplitView` DETAIL column, where a wrapping `Text` with an
                    // unbounded ideal height makes the split view size BOTH columns to it and
                    // pushes the sidebar up under the title bar (owner bug, waves 17 + 19 —
                    // guarded by `SidebarJumpMatrixTests`). A line cap + the capped width below
                    // give the message a finite ideal height; the copy is one or two sentences,
                    // so nothing truncates in practice.
                    .lineLimit(6)
            }

            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { button($0) }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
        .modifier(OptionalAccessibilityIdentifier(id: accessibilityID))
    }

    @ViewBuilder
    private func button(_ a: EmptyStateAction) -> some View {
        Group {
            if let symbol = a.systemImage {
                Button(action: a.action) { Label(a.title, systemImage: symbol) }
            } else {
                Button(a.title, action: a.action)
            }
        }
        .buttonStyle(.bordered)
        .modifier(ProminentIf(prominent: a.isProminent))
        .modifier(OptionalAccessibilityIdentifier(id: a.accessibilityID))
    }
}

/// Applies `.buttonStyle(.borderedProminent)` only when asked (a plain conditional would change
/// the view's type across branches).
private struct ProminentIf: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent { content.buttonStyle(.borderedProminent) } else { content }
    }
}

/// Sets an accessibility identifier only when one is supplied.
struct OptionalAccessibilityIdentifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

#if DEBUG
#Preview("Empty library") {
    EmptyStateView(
        systemImage: "gamecontroller",
        title: "No games yet",
        message: "Add the games you own or have played, and rank the ones worth ranking.",
        actions: [
            EmptyStateAction(title: "Quick Add", systemImage: "plus", isProminent: true, action: {}),
            EmptyStateAction(title: "Import…", systemImage: "square.and.arrow.down", action: {}),
        ])
    .frame(width: 480, height: 400)
}

#Preview("No results") {
    EmptyStateView(
        systemImage: "magnifyingglass",
        title: "No matches",
        message: "Nothing matches the current filters.",
        actions: [EmptyStateAction(title: "Clear filters", action: {})])
    .frame(width: 480, height: 400)
}
#endif
