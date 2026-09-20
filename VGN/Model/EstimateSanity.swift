import Foundation

/// Flags a game whose stored time-to-beat estimates look wrong (PLAN §5.3
/// "Suspicious estimates", owner 2026-09-20 — "some games like Visage have a fishy
/// completionist time compared to the main/rushed times; have a filter to detect
/// those cases so I can refresh them from HowLongToBeat").
///
/// A **pure** rule over the three stored times (Foundation only). The three
/// parameters use the app's column meanings:
///  - `rushed` = `ttb_hastily_s` (HLTB *Main Story*, the fastest run),
///  - `main` = `ttb_normally_s` (HLTB *Main + Extra*, "the main story"),
///  - `completionist` = `ttb_completely_s` (HLTB *Completionist*).
///
/// A game is suspicious when its times are **out of order** (`rushed > main`, or
/// `main > completionist`), when the **completionist is implausibly long**
/// (`completionist ≥ 4 × main`) or the **rushed is implausibly short**
/// (`rushed < 0.25 × main`), or when only the **completionist side exists**
/// (a completionist with no main, where IGDB usually has both).
///
/// The rule speaks only about the three numbers. Two orthogonal facts — a game
/// whose times come **from HowLongToBeat** (`ttb_source = 'hltb'`, the reference, so
/// never flagged) and a game the owner **dismissed** ("Estimate Looks Right") — are
/// applied by the callers, *around* this rule, never inside it (so the same pure
/// function serves the SQL mirror in ``LibraryQuery``, which adds those two
/// exclusions in SQL). The Swift rule and the SQL fragment are proven to agree on a
/// table of cases (`EstimateSanityTests`).
enum EstimateSanity {
    // MARK: Thresholds (the single source of truth; the SQL mirror inlines these)

    /// A completionist time this many times the main story (or longer) is suspicious
    /// (*LittleBigPlanet*: 54 h → 1 000 h).
    static let completionistRatio: Double = 4.0
    /// A rushed time below this fraction of the main story is suspicious.
    static let rushedFraction: Double = 0.25

    /// Why a game's estimates were flagged, carrying the numbers for a human sentence.
    enum Reason: Hashable, Sendable {
        /// `rushed > main` — the fastest run beats the main story.
        case rushedOverMain(rushed: Int, main: Int)
        /// `main > completionist` — the main story beats 100 %.
        case mainOverCompletionist(main: Int, completionist: Int)
        /// `completionist ≥ 4 × main` — 100 % dwarfs the main story.
        case completionistTooLong(main: Int, completionist: Int)
        /// `rushed < 0.25 × main` — the fastest run is a small fraction of the main story.
        case rushedTooShort(rushed: Int, main: Int)
        /// A completionist time with no main story (IGDB usually has both).
        case completionistWithoutMain(completionist: Int)

        /// A one-line explanation for the inspector tooltip, e.g.
        /// "Completionist (1000 h) is more than 4× the main story (54 h)".
        var sentence: String {
            switch self {
            case let .rushedOverMain(rushed, main):
                return "Rushed (\(EstimateSanity.hoursText(rushed))) is longer than the main story (\(EstimateSanity.hoursText(main)))."
            case let .mainOverCompletionist(main, completionist):
                return "The main story (\(EstimateSanity.hoursText(main))) is longer than completionist (\(EstimateSanity.hoursText(completionist)))."
            case let .completionistTooLong(main, completionist):
                return "Completionist (\(EstimateSanity.hoursText(completionist))) is more than 4× the main story (\(EstimateSanity.hoursText(main)))."
            case let .rushedTooShort(rushed, main):
                return "Rushed (\(EstimateSanity.hoursText(rushed))) is less than a quarter of the main story (\(EstimateSanity.hoursText(main)))."
            case let .completionistWithoutMain(completionist):
                return "A completionist time (\(EstimateSanity.hoursText(completionist))) with no main-story estimate."
            }
        }
    }

    /// The pure rule (PLAN §5.3): returns the first matching ``Reason``, or `nil` when
    /// the estimates look sane. Every comparison needs both of its operands present, so
    /// a missing time never trips a check (matching the SQL, where a comparison with a
    /// NULL is never true). The check order fixes which reason is reported when several
    /// apply; the *set* of flagged games is order-independent.
    static func isSuspicious(rushed: Int?, main: Int?, completionist: Int?) -> Reason? {
        if let r = rushed, let m = main, r > m {
            return .rushedOverMain(rushed: r, main: m)
        }
        if let m = main, let c = completionist, m > c {
            return .mainOverCompletionist(main: m, completionist: c)
        }
        if let m = main, let c = completionist, Double(c) >= completionistRatio * Double(m) {
            return .completionistTooLong(main: m, completionist: c)
        }
        if let r = rushed, let m = main, Double(r) < rushedFraction * Double(m) {
            return .rushedTooShort(rushed: r, main: m)
        }
        if main == nil, let c = completionist {
            return .completionistWithoutMain(completionist: c)
        }
        return nil
    }

    /// Whether a game is flagged, applying the two caller-side exclusions the SQL also
    /// applies: an `hltb`-sourced game is the reference and never flagged; a dismissed
    /// game ("Estimate Looks Right") is never flagged.
    static func isFlagged(rushed: Int?, main: Int?, completionist: Int?,
                          sourceIsHLTB: Bool, dismissed: Bool) -> Bool {
        guard !sourceIsHLTB, !dismissed else { return false }
        return isSuspicious(rushed: rushed, main: main, completionist: completionist) != nil
    }

    // MARK: Personal-length fallback (D5)

    /// The `(main, completionist)` pair to feed into ``PersonalLength/compute`` so a
    /// **flagged completionist is ignored** for planning (PLAN §5.3 — the personal
    /// length, the BY LENGTH shelves and Play Next fall back until the game is refreshed
    /// or dismissed). The fallback (`main × PlayStyle.sidesRatio`) only makes sense **when
    /// a main exists**, so it applies to exactly the completionist-inflated case:
    ///
    /// - an `hltb`-sourced or dismissed game keeps its raw pair (never rewritten),
    /// - `completionist ≥ 4 × main` → completionist becomes `main × PlayStyle.sidesRatio`
    ///   (so the blend equals the main-only estimate),
    /// - everything else → the raw pair. A game whose **main** is the implausible one
    ///   (`rushed > main`, `main > completionist`) keeps its stored pair, which the
    ///   ``PersonalLength`` clamp already treats conservatively (a `completionist < main`
    ///   collapses to the main story). A **lone completionist** (no main, still flagged so
    ///   the owner can refresh it) has no main to fall back to, so it keeps its stored
    ///   completionist-only estimate rather than becoming Unmeasured.
    ///
    /// The SQL mirror lives in ``LibraryQuery/lengthEstimateExpr(style:r:)``.
    static func lengthInputs(rushed: Int?, main: Int?, completionist: Int?,
                             sourceIsHLTB: Bool, dismissed: Bool) -> (main: Int?, completionist: Int?) {
        guard !sourceIsHLTB, !dismissed else { return (main, completionist) }
        if let m = main, let c = completionist, Double(c) >= completionistRatio * Double(m) {
            return (m, Int((Double(m) * PlayStyle.sidesRatio).rounded()))
        }
        return (main, completionist)
    }

    // MARK: Formatting

    /// Whole-ish hours for a human sentence, locale-independent: whole hours when the
    /// value is a whole number of hours, else one decimal ("54 h", "1000 h", "2.5 h").
    static func hoursText(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3600
        let rounded = (hours * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) h"
        }
        return String(format: "%.1f h", rounded)
    }
}
