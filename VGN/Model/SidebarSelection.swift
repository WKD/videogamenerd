import Foundation

/// What the sidebar has selected — the single source of truth for what the
/// grid, search, filters, Top and Quick Add's default platform are scoped to
/// (PLAN §8).
///
/// romlord's documented gotcha: the `List` selection binding, every `.tag(…)`,
/// and this type must be *exactly* the same type, or selection silently breaks.
/// So this is the one selection type; use it everywhere a tag is attached.
enum SidebarSelection: Hashable, Sendable, Identifiable {
    // Smart lists (PLAN §8)
    case all
    case owned
    case played
    case backlog
    case unranked

    // Ranking views (PLAN §7)
    case tierBoard
    case theTop
    case duel

    // A single platform, keyed by its slug (e.g. "ps5", "snes", "pc").
    case platform(String)

    /// Stable identity for `ForEach` / `Identifiable` use.
    var id: String {
        switch self {
        case .all: return "all"
        case .owned: return "owned"
        case .played: return "played"
        case .backlog: return "backlog"
        case .unranked: return "unranked"
        case .tierBoard: return "tierBoard"
        case .theTop: return "theTop"
        case .duel: return "duel"
        case .platform(let slug): return "platform:\(slug)"
        }
    }

    /// The smart lists that appear under the "Library" header, in order.
    static let smartLists: [SidebarSelection] = [.all, .owned, .played, .backlog, .unranked]

    /// The ranking destinations under the "Rankings" header, in order.
    static let rankingViews: [SidebarSelection] = [.tierBoard, .theTop, .duel]

    /// The platform slug when this selection is a platform, else nil.
    var platformSlug: String? {
        if case .platform(let slug) = self { return slug }
        return nil
    }
}
