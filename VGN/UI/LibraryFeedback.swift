import Foundation

/// A transient, non-blocking message shown over the library (PLAN §8: intent
/// errors and skip notices are surfaced, never swallowed).
struct LibraryBanner: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case info, warning, error }
    let id = UUID()
    var message: String
    var kind: Kind
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
