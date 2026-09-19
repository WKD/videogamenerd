import Foundation

/// A playtime band for the library "Playtime" filter (PLAN §6.4/§8 — "Playtime
/// bands"). The value a game is bucketed on is its **effective** playtime (manual
/// over PSN); for a game I have not played it falls back to the best available IGDB
/// estimate (main → rushed → completionist — the UI labels this clearly).
///
/// Bands (inclusive lower, exclusive upper): < 10 h · 10–40 h · 40–60 h · 60–80 h ·
/// 80–100 h · 100–150 h · 150–200 h · > 200 h.
///
/// The raw values of `short` (< 10 h) and `medium` (10–40 h) are stable — they kept
/// their meaning across the finer-bands change. The old `long` (> 40 h) no longer
/// exists; its raw value now decodes to `nil` via the failable initializer (nothing
/// persists these, but a stray value is ignored rather than crashing — see
/// ``PlaytimeBucketTests``).
enum PlaytimeBucket: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case short     // < 10 h
    case medium    // 10–40 h
    case h40to60   // 40–60 h
    case h60to80   // 60–80 h
    case h80to100  // 80–100 h
    case h100to150 // 100–150 h
    case h150to200 // 150–200 h
    case over200   // > 200 h

    var id: String { rawValue }

    /// The single source of truth for every band's bounds, in **hours**:
    /// `(lowerInclusive, upperExclusive)`, `nil` = unbounded on that side. Labels,
    /// the SQL band clause and the in-memory ``contains(_:)`` all derive from this,
    /// so they cannot drift.
    var hourBounds: (lower: Int?, upper: Int?) {
        switch self {
        case .short:     return (nil, 10)
        case .medium:    return (10, 40)
        case .h40to60:   return (40, 60)
        case .h60to80:   return (60, 80)
        case .h80to100:  return (80, 100)
        case .h100to150: return (100, 150)
        case .h150to200: return (150, 200)
        case .over200:   return (200, nil)
        }
    }

    var label: String {
        switch (hourBounds.lower, hourBounds.upper) {
        case let (nil, upper?):   return "< \(upper) h"
        case let (lower?, nil):   return "> \(lower) h"
        case let (lower?, upper?): return "\(lower)–\(upper) h"
        case (nil, nil):          return ""
        }
    }

    /// Inclusive-lower, exclusive-upper bounds in seconds (nil = unbounded).
    var lowerSeconds: Int? { hourBounds.lower.map { $0 * 3600 } }
    var upperSeconds: Int? { hourBounds.upper.map { $0 * 3600 } }

    /// Whether `seconds` falls in this band. Pure — unit-tested, and the parity
    /// counterpart to the SQL band clause in `LibraryQuery`.
    func contains(_ seconds: Int) -> Bool {
        if let lower = lowerSeconds, seconds < lower { return false }
        if let upper = upperSeconds, seconds >= upper { return false }
        return true
    }
}
