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

/// How an owned copy is licensed through a subscription, or `nil` when it is really
/// owned (PLAN §13.3 "PS Plus copies"). Stored in `products.subscription` (v8):
/// `NULL` = a copy I really own; `'ps_plus'` = a PS Plus claim that **expires with the
/// subscription**. It is a **tolerant** wrapper, not a closed enum: an unknown
/// membership string a future PSN response carries (or another service like GOG's
/// subscription tiers) is kept **raw and shown**, never guessed or dropped — so the
/// schema needs no rebuild when Sony adds a value.
struct ProductSubscription: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    /// A PS Plus claim (the only value VGN mints today). A licence that ends when the
    /// subscription lapses (PLAN §13.3).
    static let psPlus = ProductSubscription(rawValue: "ps_plus")

    var isPSPlus: Bool { self == .psPlus }

    /// A short, human-readable label for the inspector / exports. Known values get a
    /// friendly name; an unknown raw value is shown as-is (PLAN §13.3 "kept raw and shown").
    var label: String {
        switch rawValue {
        case ProductSubscription.psPlus.rawValue: return "PS Plus"
        default: return rawValue
        }
    }

    /// Build from a stored/imported string, or `nil` for an empty/absent value
    /// (which means "really owned"). A canonical `PS_PLUS`/`ps_plus` in any case folds
    /// to ``psPlus``; every other non-empty value is kept raw.
    init?(storage raw: String?) {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.compare("ps_plus", options: .caseInsensitive) == .orderedSame
            || trimmed.compare("PS_PLUS", options: .caseInsensitive) == .orderedSame {
            self = .psPlus
        } else {
            self = ProductSubscription(rawValue: trimmed)
        }
    }
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
    /// A ROM copy promoted from the Batocera catalogue (owned; played when the box
    /// records > 5 min), recognised on re-sync by `(source, external_id)` = the
    /// `<system>/<relativePath>` pair (PLAN §15).
    case batocera

    /// A short, human-readable label for the inspector / exports.
    var label: String {
        switch self {
        case .manual: return "Manual"
        case .photo: return "Photo scan"
        case .psn: return "PSN"
        case .gog: return "GOG"
        case .delicious: return "Delicious Library"
        case .batocera: return "Batocera"
        }
    }
}
