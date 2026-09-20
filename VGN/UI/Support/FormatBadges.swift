import Foundation

/// The ownership-format badges a grid tile shows (PLAN §8, owner request wave 17):
/// **one badge per distinct format among the game's really-owned copies**, in a fixed
/// order — physical (a disc) → digital (a download) → ROM (the purple chip) → PS Plus
/// (the subscription claim). The generic "Owned" box is gone: any format badge means
/// owned. A subscription-only game shows only the PS Plus badge; a game with a real
/// digital copy **and** a PS Plus claim shows both.
///
/// Pure: it reads only the per-format facts on ``GameSummary`` (populated by the grid
/// SQL) so the tile draws without a DB round-trip, and the ordering is unit-tested.
enum FormatBadgeKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case physical
    case digital
    case rom
    case psPlus

    var id: String { rawValue }
}

/// One badge to draw: its kind and the platforms of the copies it stands for (for the
/// tooltip "Physical · PS3", "Digital · PS5, PC").
struct FormatBadge: Sendable, Hashable, Identifiable {
    var kind: FormatBadgeKind
    var platformIDs: [String]
    var id: FormatBadgeKind { kind }
}

enum FormatBadges {
    /// The badges for a game, in draw order. Empty when the game owns nothing.
    static func badges(for game: GameSummary) -> [FormatBadge] {
        var out: [FormatBadge] = []
        if game.hasPhysical { out.append(FormatBadge(kind: .physical, platformIDs: game.physicalPlatformIDs)) }
        if game.hasDigital { out.append(FormatBadge(kind: .digital, platformIDs: game.digitalPlatformIDs)) }
        if game.hasROM || !game.romPlatformIDs.isEmpty {
            out.append(FormatBadge(kind: .rom, platformIDs: game.romPlatformIDs))
        }
        if game.hasSubscription { out.append(FormatBadge(kind: .psPlus, platformIDs: game.subscriptionPlatformIDs)) }
        return out
    }
}
