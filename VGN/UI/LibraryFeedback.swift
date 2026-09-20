import Foundation

/// A transient, non-blocking message shown over the library (PLAN §8: intent
/// errors and skip notices are surfaced, never swallowed).
struct LibraryBanner: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case info, warning, error }
    let id = UUID()
    var message: String
    var kind: Kind
    /// An optional action affordance rendered as a button (e.g. "Review…", PLAN §15). When
    /// set, the banner does **not** auto-dismiss — it waits for the action or the ✕. The
    /// handler itself lives on ``LibraryViewModel`` (a closure is not `Equatable`/`Sendable`).
    var actionTitle: String? = nil
    /// An optional **second** action (e.g. Undo + "Review…" on the Batocera auto-add banner,
    /// PLAN §15). Its handler also lives on ``LibraryViewModel``. Only meaningful alongside
    /// ``actionTitle``.
    var secondaryActionTitle: String? = nil
}

/// A yes/no confirmation the user must answer before a destructive retry (an
/// orphan-delete on un-play, or removing a game's last copy — PLAN §4 inv. 1).
/// `perform` runs the confirmed action (typically a retry with
/// `confirmOrphanDelete: true`).
@MainActor
struct LibraryConfirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmTitle: String
    var isDestructive: Bool
    var perform: () -> Void
}

/// A request to choose a platform + format when marking a game owned needs more
/// than a single obvious copy (PLAN §8: platform picker limited to the game's
/// platforms with "Other…" → all platforms, format from `ProductFormat.allCases`).
@MainActor
struct OwnershipRequest: Identifiable {
    let id = UUID()
    var gameID: Int64
    var title: String
    /// The game's own platforms (the primary picker choices).
    var gamePlatforms: [PlatformInfo]
    /// Every platform (revealed by "Other…").
    var allPlatforms: [PlatformInfo]
    /// Confirm with a chosen platform slug + format.
    var perform: (_ platformID: String, _ format: ProductFormat) -> Void
}

/// A request to choose which owned copies to remove when un-owning a game that
/// has one or more copies (PLAN §8). Compilation copies warn that the whole
/// compilation — and its listed member games — is affected.
@MainActor
struct CopyRemovalRequest: Identifiable {
    let id = UUID()
    var title: String
    var copies: [Choice]
    var perform: (_ productIDs: [Int64]) -> Void

    struct Choice: Identifiable {
        var id: Int64 { productID }
        var productID: Int64
        var label: String
        var isCompilation: Bool
        /// Member game titles for a compilation copy (for the warning).
        var compilationMembers: [String]
    }
}

/// A request to group several selected games into one compilation product
/// (PLAN §8 — "Group as compilation…": title + platform + format → one product
/// owning them; existing singles on that platform can be merged in).
@MainActor
struct GroupCompilationRequest: Identifiable {
    let id = UUID()
    /// The games to group, in selection order (each `(id, title)`).
    var games: [(id: Int64, title: String)]
    /// The platforms the group can target (the games' shared / union platforms).
    var platforms: [PlatformInfo]
    /// Confirm with a title, platform slug, format, and whether to merge singles.
    var perform: (_ title: String, _ platformID: String, _ format: ProductFormat, _ mergeSingles: Bool) -> Void
}
