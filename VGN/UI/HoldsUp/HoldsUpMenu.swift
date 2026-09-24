import SwiftUI

/// The **Holds Up Today?** submenu items (PLAN §7b/§8) — shared by the grid context menu and
/// the menu-bar Game menu so both render the same mixed state: the three values + Clear, each
/// ✓ (every played target has it) / – (some do) / nothing, computed only over the **played**
/// targets. Unplayed targets are ignored and named in a disabled footer (like Change Copy
/// Format's several-copies footer). PURE — built from already-loaded summaries; every write
/// happens in `onPick`.
struct HoldsUpMenuItems: View {
    /// The games the menu acts on (already-loaded summaries — never a DB read).
    let targets: [GameSummary]
    /// Whether the items are enabled (e.g. the Game menu's grid-destination check).
    var isEnabled: Bool = true
    /// Register the ⌃⌥⌘1/2/3/0 key equivalents — ONLY on the menu-bar Game menu (the one place
    /// they are registered; see ``HoldsUpInspectorRow``).
    var registersShortcuts: Bool = false
    let onPick: (HoldsUp?) -> Void

    var body: some View {
        let playedCount = targets.reduce(0) { $0 + ($1.played ? 1 : 0) }
        let enabled = isEnabled && playedCount > 0
        ForEach(HoldsUp.allCases) { value in
            StateMenuButton(title: value.label, state: targets.holdsUpState(value)) { onPick(value) }
                .disabled(!enabled)
                .help(value.explanation)
                .holdsUpShortcut(registersShortcuts ? HoldsUpInspectorRow.key(for: value) : nil)
        }
        Divider()
        StateMenuButton(title: "Clear (Unrated)", state: targets.holdsUpState(nil)) { onPick(nil) }
            .disabled(!enabled)
            .holdsUpShortcut(registersShortcuts ? "0" : nil)
        let unplayed = targets.unplayedCount
        if unplayed > 0 {
            Divider()
            Button { } label: { Text(Self.unplayedFooter(unplayed)) }
                .disabled(true)
        }
    }

    /// "2 unplayed games not changed" — only a played game can be rated.
    static func unplayedFooter(_ n: Int) -> String {
        n == 1 ? "1 unplayed game not changed" : "\(n) unplayed games not changed"
    }

    /// The submenu title everywhere.
    static let title = "Holds Up Today?"
}

private extension View {
    /// ⌃⌥⌘`key` when non-nil, else nothing.
    @ViewBuilder
    func holdsUpShortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key, modifiers: HoldsUpInspectorRow.modifiers) } else { self }
    }
}
