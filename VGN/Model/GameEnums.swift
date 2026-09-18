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

/// How a product entered the library (PLAN §4).
enum ProductSource: String, Hashable, Sendable, Codable, CaseIterable {
    case manual
    case photo
    case psn
}
