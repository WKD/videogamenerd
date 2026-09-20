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

    // Play Next recommendation (PLAN §7b) — LIBRARY section, after Unranked.
    case playNext

    /// Games not linked to an IGDB entry (`igdb_id IS NULL`): they get no metadata,
    /// cover, time-to-beat or traits, and are invisible to the `igdb_id` dedupe, so a
    /// later import can duplicate them (PLAN §5.1 "Reconciling unlinked games"). A
    /// LIBRARY row shown **only when its count > 0** (like "Unmeasured").
    case unlinked

    /// Library games whose title looks like an unexpanded bundle/pack (Trilogy, Collection,
    /// "3-in-1"…) imported as one game — the repair-path candidate list (PLAN §5.1). A LIBRARY
    /// row placed right under Unlinked, shown **only when its count > 0** (like Unlinked). The
    /// candidate rule lives in ``LibraryStore/fetchBundleExpansionCandidates(_:)``; selecting
    /// this scopes the grid to those game ids so the owner can expand them into their members.
    case bundlesToExpand

    /// Library games that are IGDB **DLC / expansions / packs / seasons / updates / mods** rather
    /// than games in their own right (PLAN §5.1 "What counts as a game"). Driven purely by the
    /// game's own cached IGDB `game_type` (no request). A LIBRARY row under Bundles to Expand,
    /// shown **only when its count > 0**.
    case dlcAndExpansions

    /// Library games that are an IGDB **port** (game_type 11) whose parent game is **also** in the
    /// library — the "same game, two entries" pairs the owner may want to merge (PLAN §5.1). A
    /// LIBRARY row under Bundles to Expand, shown **only when its count > 0**; the header/context
    /// action runs the existing reconcile merge with the parent as target.
    case sameGameTwoEntries

    // Ranking views (PLAN §7)
    case tierBoard
    case theTop
    case duel

    // "By Length" smart lists (PLAN §8) — games grouped by their time-to-beat
    // *estimate*, in the section after RANKINGS and before PLATFORMS.
    case length(LengthShelf)
    /// Games with no time-to-beat estimate at all (the "Unmeasured" catch-all row).
    case unmeasured

    /// A **Vault** browser for one source (PLAN §16) — a "THE VAULT" section row (Batocera
    /// ROMs / PS Plus) shown only when that source is non-empty. It routes to a **separate**
    /// view (``RomCatalogueView``), never the library grid, and never affects any library
    /// count, stat, ranking or export. Stable ids `vault:batocera` / `vault:psn`.
    case vault(VaultSource)

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
        case .playNext: return "playNext"
        case .unlinked: return "unlinked"
        case .bundlesToExpand: return "bundlesToExpand"
        case .dlcAndExpansions: return "dlcAndExpansions"
        case .sameGameTwoEntries: return "sameGameTwoEntries"
        case .tierBoard: return "tierBoard"
        case .theTop: return "theTop"
        case .duel: return "duel"
        case .length(let shelf): return "length:\(shelf.id)"
        case .unmeasured: return "unmeasured"
        case .vault(let source): return source.sidebarID
        case .platform(let slug): return "platform:\(slug)"
        }
    }

    /// The smart lists that appear under the "Library" header, in order.
    static let smartLists: [SidebarSelection] = [.all, .owned, .played, .backlog, .unranked, .playNext]

    /// The ranking destinations under the "Rankings" header, in order.
    static let rankingViews: [SidebarSelection] = [.tierBoard, .theTop, .duel]

    /// The "By Length" shelves under the "By Length" header, in order (the
    /// "Unmeasured" catch-all is shown separately, only when it has games).
    static let lengthShelves: [SidebarSelection] = LengthShelf.allCases.map(SidebarSelection.length)

    /// The platform slug when this selection is a platform, else nil.
    var platformSlug: String? {
        if case .platform(let slug) = self { return slug }
        return nil
    }
}
