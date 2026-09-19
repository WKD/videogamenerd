import Foundation

/// Why locating or reading the Batocera share failed (PLAN §15). Designed so one bad
/// system never throws away a whole sync: ``BatoceraShare`` reports a per-file failure
/// (`.unreadableFile` / `.malformedGamelist`) and moves on, while the share-level cases
/// (`.shareNotMounted` / `.noRomsFolder`) end the sync quietly (the NAS is asleep or the
/// owner is away — "nothing happens, and nothing complains").
enum BatoceraError: Error, Sendable, Hashable {
    /// The chosen share root does not exist / is not reachable (NAS unmounted).
    case shareNotMounted(path: String)
    /// The share is mounted but has no `roms` folder (or no system subfolders).
    case noRomsFolder(path: String)
    /// One system's `gamelist.xml` could not be opened / read.
    case unreadableFile(system: String, path: String)
    /// One system's `gamelist.xml` is present but malformed (XML parse error).
    case malformedGamelist(system: String, detail: String)

    var isShareLevel: Bool {
        switch self {
        case .shareNotMounted, .noRomsFolder: return true
        case .unreadableFile, .malformedGamelist: return false
        }
    }

    var message: String {
        switch self {
        case .shareNotMounted(let path):
            return "The Batocera share is not mounted (\(path))."
        case .noRomsFolder(let path):
            return "No roms folder was found under \(path)."
        case .unreadableFile(let system, let path):
            return "Could not read \(system)'s gamelist (\(path))."
        case .malformedGamelist(let system, let detail):
            return "\(system)'s gamelist.xml is malformed: \(detail)"
        }
    }
}
