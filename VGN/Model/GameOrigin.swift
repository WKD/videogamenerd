import Foundation

/// How a *game* first entered the library, recorded for debugging (owner request,
/// wave 9). Distinct from a copy's ``ProductSource``: a played-only game (no
/// product) still has an origin, and PSN will soon create many such games.
///
/// Set once, at creation time, from the source of the game's first product (or
/// `manual` when it has none) — never changed when a later copy is added. Stored in
/// `games.origin` as a plain string with no DB CHECK, so a future importer needs no
/// table rebuild; validation is here in Swift. Unknown strings round-trip through
/// ``other(_:)`` so an origin written by a newer build is never lost.
enum GameOrigin: Hashable, Sendable {
    case manual
    case photo
    case psn
    case gog
    /// Any origin string this build does not know (forward-compatible decode).
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "manual": self = .manual
        case "photo": self = .photo
        case "psn": self = .psn
        case "gog": self = .gog
        default: self = .other(rawValue)
        }
    }

    /// Tolerant decode of a nullable column; `nil`/blank ⇒ nil.
    init?(storage: String?) {
        guard let raw = storage?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        self.init(rawValue: raw)
    }

    /// A game's origin is the source of its first product; a played-only game has
    /// none, so it enters as `manual`.
    init(productSource: ProductSource) {
        self.init(rawValue: productSource.rawValue)
    }

    var rawValue: String {
        switch self {
        case .manual: return "manual"
        case .photo: return "photo"
        case .psn: return "psn"
        case .gog: return "gog"
        case .other(let s): return s
        }
    }

    /// A short, human-readable label for the inspector / exports.
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .photo: return "Photo scan"
        case .psn: return "PSN"
        case .gog: return "GOG"
        case .other(let s): return s.capitalized
        }
    }
}
