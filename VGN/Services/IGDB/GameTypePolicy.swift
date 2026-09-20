import Foundation

/// The single policy that decides, from IGDB's `game_type`, what VGN does with an
/// entry when it is produced as a bundle member or a match (PLAN §5.1, owner
/// 2026-09-20 — "what counts as a game"). Pure Foundation, table-driven, so every
/// producer path (Quick Add, photo scan, import review, reconcile / Expand Bundle,
/// batch expand, Batocera) shares one set of rules.
enum GameTypePolicy {

    /// Is this entry a game in its own right — kept as a bundle member and a legitimate
    /// match? **FALSE** only for content that was sold *inside* another game:
    /// `dlc_addon` (1), `expansion` (2), `mod` (5), `season` (7), `pack` (13),
    /// `update` (14). **TRUE** for everything else, including:
    /// - `main_game` (0),
    /// - `bundle` (3) — a compilation, expanded elsewhere,
    /// - `standalone_expansion` (4) and `episode` (6) — sold and played on their own
    ///   (Far Cry 3: Blood Dragon, the Walking Dead episodes),
    /// - `remake` (8), `remaster` (9), `expanded_game` (10) — different enough to rank
    ///   separately,
    /// - `port` (11) and `fork` (12),
    /// - `unknown`/nil — never drop what we cannot classify.
    static func isStandaloneGame(_ type: IGDBGameType) -> Bool {
        switch type {
        case .dlcAddon, .expansion, .mod, .season, .pack, .update: return false
        default: return true
        }
    }

    /// Does this entry fold into its parent game — i.e. it is the SAME game on another
    /// platform / re-release, not a distinct thing to rank? **TRUE only for `port`
    /// (11)** (PLAN §5.1: a Switch/PS4 port lands on the one game, gaining a copy).
    /// Remake (8), remaster (9) and expanded (10) stay separate games.
    static func foldsIntoParent(_ type: IGDBGameType) -> Bool {
        type == .port
    }

    /// A human label describing a non-main entry, for a result row or a folded note —
    /// "Expansion of Diablo II", "DLC for Diablo II", "Port of Super Mario Galaxy".
    /// `parentName` fills the "… of/for X"; nil (or a `main`/`unknown` type) yields the
    /// bare kind, or `nil` when there is nothing worth saying (a plain main game).
    static func label(for type: IGDBGameType, parentName: String? = nil) -> String? {
        func suffix(_ preposition: String) -> String {
            parentName.map { " \(preposition) \($0)" } ?? ""
        }
        switch type {
        case .mainGame, .unknown: return nil
        case .dlcAddon:            return "DLC" + suffix("for")
        case .expansion:           return "Expansion" + suffix("of")
        case .standaloneExpansion: return "Standalone expansion" + suffix("of")
        case .mod:                 return "Mod" + suffix("for")
        case .episode:             return "Episode" + suffix("of")
        case .season:              return "Season" + suffix("of")
        case .remake:              return "Remake" + suffix("of")
        case .remaster:            return "Remaster" + suffix("of")
        case .expandedGame:        return "Expanded edition" + suffix("of")
        case .port:                return "Port" + suffix("of")
        case .fork:                return "Fork" + suffix("of")
        case .bundle:              return "Bundle"
        case .pack:                return "Pack" + suffix("of")
        case .update:              return "Update" + suffix("of")
        }
    }

    /// The bare kind word shown after a dropped member in the "left out" list —
    /// "Season of Infamy — **expansion**" (PLAN §5.1 confirm step).
    static func droppedKindLabel(_ type: IGDBGameType) -> String {
        switch type {
        case .dlcAddon: return "DLC"
        case .expansion: return "expansion"
        case .mod: return "mod"
        case .season: return "season"
        case .pack: return "pack"
        case .update: return "update"
        default: return "add-on"     // only reached for a dropped (non-standalone) type
        }
    }
}
