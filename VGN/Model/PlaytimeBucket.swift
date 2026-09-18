import Foundation

/// A coarse playtime band for the library "Playtime" filter (PLAN §6.4 —
/// "sortable/filterable"). The value a game is bucketed on is its **effective**
/// playtime (manual over PSN); for a game I have not played it falls back to the
/// IGDB main (`normally`) estimate — the UI labels this clearly.
enum PlaytimeBucket: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case short   // < 10 h
    case medium  // 10–40 h
    case long    // > 40 h

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return "< 10 h"
        case .medium: return "10–40 h"
        case .long: return "> 40 h"
        }
    }

    /// Inclusive-lower, exclusive-upper bounds in seconds (nil = unbounded).
    var lowerSeconds: Int? {
        switch self {
        case .short: return nil
        case .medium: return 10 * 3600
        case .long: return 40 * 3600
        }
    }
    var upperSeconds: Int? {
        switch self {
        case .short: return 10 * 3600
        case .medium: return 40 * 3600
        case .long: return nil
        }
    }

    /// Whether `seconds` falls in this bucket. Pure — unit-tested.
    func contains(_ seconds: Int) -> Bool {
        if let lower = lowerSeconds, seconds < lower { return false }
        if let upper = upperSeconds, seconds >= upper { return false }
        return true
    }
}
