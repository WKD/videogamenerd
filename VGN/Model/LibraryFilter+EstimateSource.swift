import Foundation

/// Where a game's time-to-beat estimates come from — the **Playtime ▸ Estimate Source**
/// facet (PLAN §5.3/§8, deferred from wave 21 W21-B, built wave 22). Three mutually
/// exclusive, exhaustive values over the three stored times and `ttb_source`:
///
/// - ``hltb`` — at least one time is stored and `ttb_source = 'hltb'` (HowLongToBeat, the
///   reference — refreshed or filled from HLTB);
/// - ``igdb`` — at least one time is stored and the source is anything else (IGDB's
///   `'igdb'`, or a legacy row with no source tag — IGDB was the only automatic filler
///   before HowLongToBeat);
/// - ``none`` — no time at all (rushed, main and completionist all empty).
///
/// Pure (Foundation only). ``classify(rushed:main:completionist:source:)`` is the Swift rule;
/// ``LibraryQuery/estimateSourceSQL`` is its SQL mirror (parity-tested), and the grid row
/// carries the value (``GameSummary/estimateSource``) so the in-memory evaluator agrees.
enum EstimateSource: String, Hashable, Sendable, CaseIterable, Identifiable {
    case igdb
    case hltb
    case none

    var id: String { rawValue }

    /// The menu / chip label.
    var label: String {
        switch self {
        case .igdb: return "IGDB"
        case .hltb: return "HowLongToBeat"
        case .none: return "None"
        }
    }

    /// The pure rule (see the type doc). `source` is the raw `ttb_source` column.
    static func classify(rushed: Int?, main: Int?, completionist: Int?, source: String?) -> EstimateSource {
        guard rushed != nil || main != nil || completionist != nil else { return .none }
        return source == "hltb" ? .hltb : .igdb
    }
}
