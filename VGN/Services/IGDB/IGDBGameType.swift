import Foundation

/// IGDB's `game_type` (the integer that replaced the deprecated `category` field).
/// Values are the historical `category` ids, verified against the live `/v4/game_types`
/// endpoint during fixture recording. Anything we do not recognise is preserved as
/// `.unknown(Int)` so a future IGDB addition never drops a game on the floor.
enum IGDBGameType: Sendable, Equatable, Hashable {
    case mainGame           // 0
    case dlcAddon           // 1
    case expansion          // 2
    case bundle             // 3  (PLAN §5.1 compilations)
    case standaloneExpansion // 4
    case mod                // 5
    case episode            // 6
    case season             // 7
    case remake             // 8
    case remaster           // 9
    case expandedGame       // 10
    case port               // 11
    case fork               // 12
    case pack               // 13
    case update             // 14
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0: self = .mainGame
        case 1: self = .dlcAddon
        case 2: self = .expansion
        case 3: self = .bundle
        case 4: self = .standaloneExpansion
        case 5: self = .mod
        case 6: self = .episode
        case 7: self = .season
        case 8: self = .remake
        case 9: self = .remaster
        case 10: self = .expandedGame
        case 11: self = .port
        case 12: self = .fork
        case 13: self = .pack
        case 14: self = .update
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .mainGame: return 0
        case .dlcAddon: return 1
        case .expansion: return 2
        case .bundle: return 3
        case .standaloneExpansion: return 4
        case .mod: return 5
        case .episode: return 6
        case .season: return 7
        case .remake: return 8
        case .remaster: return 9
        case .expandedGame: return 10
        case .port: return 11
        case .fork: return 12
        case .pack: return 13
        case .update: return 14
        case .unknown(let value): return value
        }
    }

    /// True for the compilation-like types whose member games VGN can expand
    /// (PLAN §5.1: bundles/compilations become one Product with n Games).
    var isCompilation: Bool {
        switch self {
        case .bundle, .pack: return true
        default: return false
        }
    }

    /// Content that is not a game in its own right (DLC, packs, updates, mods) — never
    /// listed as a compilation member.
    var isAddOnContent: Bool {
        switch self {
        case .dlcAddon, .mod, .pack, .update: return true
        default: return false
        }
    }
}
