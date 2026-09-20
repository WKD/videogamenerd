import Foundation

/// One entry a bundle expansion did **not** keep as a plain member (PLAN §5.1), so the
/// confirm step can say what happened instead of dropping it silently:
/// - a non-standalone member that was **dropped** ("Season of Infamy — expansion"),
/// - a **port** that was **folded** onto its parent game ("Super Mario Galaxy → the
///   2007 original").
struct BundleLeftOut: Sendable, Equatable, Codable, Identifiable, Hashable {
    /// The member's own IGDB title.
    var title: String
    /// The trailing note: the bare kind for a drop ("expansion"), or the "→ …" target
    /// for a fold ("→ the 2007 original").
    var reason: String
    /// True when the member was folded onto its parent (a port); false when dropped.
    var folded: Bool

    var id: String { "\(title)|\(reason)|\(folded)" }

    /// One line for a confirm sheet: "Season of Infamy — expansion" (dropped) or
    /// "Super Mario Galaxy → the 2007 original" (folded).
    var displayText: String { folded ? "\(title) \(reason)" : "\(title) — \(reason)" }

    static func dropped(_ title: String, kind: String) -> BundleLeftOut {
        BundleLeftOut(title: title, reason: kind, folded: false)
    }
    static func folded(_ title: String, to note: String) -> BundleLeftOut {
        BundleLeftOut(title: title, reason: note, folded: true)
    }
}

/// The outcome of resolving a bundle's members through the one member policy
/// (PLAN §5.1): the members VGN keeps (non-standalone content dropped, ports folded
/// onto their parent, de-duplicated, release-date ordered) plus the ``BundleLeftOut``
/// notes for everything that was dropped or folded, so every confirm UI can show it.
struct BundleMemberResult: Sendable, Equatable {
    var members: [IGDBSearchResult]
    var leftOut: [BundleLeftOut]

    init(members: [IGDBSearchResult] = [], leftOut: [BundleLeftOut] = []) {
        self.members = members
        self.leftOut = leftOut
    }

    /// Fewer than two members left ⇒ no longer worth a compilation (PLAN §5.1): the
    /// caller adds the lone member as a single game, or falls back to its single-game
    /// path when empty.
    var isWorthCompilation: Bool { members.count >= 2 }
}
