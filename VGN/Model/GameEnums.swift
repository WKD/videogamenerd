import Foundation

/// Optional completion status for a *played* game (PLAN §12, "Completion status").
enum PlayStatus: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case playing
    case finished
    case completed   // 100%
    case abandoned

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playing: return "Playing"
        case .finished: return "Finished"
        case .completed: return "100%"
        case .abandoned: return "Abandoned"
        }
    }
}

/// Whether an owned product is a physical copy, a digital licence, or a ROM
/// (PLAN §4). A ROM is a first-class way to own a game, entered manually.
enum ProductFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case physical
    case digital
    case rom

    var label: String {
        switch self {
        case .physical: return "Physical"
        case .digital: return "Digital"
        case .rom: return "ROM"
        }
    }
}

/// A product is a single game or a compilation of many (PLAN §4).
enum ProductKind: String, Hashable, Sendable, Codable, CaseIterable {
    case single
    case compilation
}

/// How a product entered the library (PLAN §4 / §14.3). `gog` is a GOG-import Product
/// (owned digital PC/Mac), recognised on re-sync by `(source, external_id)`.
enum ProductSource: String, Hashable, Sendable, Codable, CaseIterable {
    case manual
    case photo
    case psn
    case gog
    /// A copy imported from an old Delicious Library 2 catalogue (owned, physical),
    /// recognised on re-import by `(source, external_id)` (PLAN §5.5).
    case delicious

    /// A short, human-readable label for the inspector / exports.
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .photo: return "Photo scan"
        case .psn: return "PSN"
        case .gog: return "GOG"
        case .delicious: return "Delicious Library"
        }
    }
}
