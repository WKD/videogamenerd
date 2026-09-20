import Foundation

/// The PS Plus **deadline ramp** (PLAN §16 — "play them before I unsubscribe"): a pure,
/// additive, backtest-excluded score term for games that leave when the owner cancels PS Plus
/// — library copies owned only via the subscription (the "+" badge) and PS Plus Vault entries.
///
/// Two factors multiply:
///  - **urgency** — a smooth ramp that grows as the cancellation date approaches: modest
///    beyond a year, clearly visible inside six months, strongest in the last three. A Hill
///    curve `1 / (1 + (months / halfLife)^p)` (`halfLife = 6`, `p = 2`), so it is C∞ and
///    monotonically non-increasing in months-left, and urgency(6) = ½ by construction.
///  - **finishability** — how comfortably the game still fits: personal length (§8, play
///    style) versus the hours left at the owner's weekly pace (§15). Full while the length is
///    at most ~half the hours left, fading to zero once it no longer fits; an unknown length is
///    a neutral ½ (a ROM in the Vault usually has no length, so it neither leads nor is buried).
///
/// The product scales the one magnitude constant ``Constants/maxBoost``, kept small enough that
/// the term "can lift a PS Plus game above near-equals but never above a clearly better fit"
/// (PLAN §16). Foundation only; every rule is independently testable.
enum PSPlusDeadlineBoost {

    /// Every tunable in one place (PLAN §16 — "constants in one place").
    struct Constants: Sendable, Hashable {
        /// The strongest the term can ever be (urgency = finishability = 1). Below the taste
        /// and crowd spreads, so it only reorders near-ties.
        var maxBoost: Double = 0.10
        /// Months-left at which urgency = ½ (the "clearly visible inside six months" anchor).
        var urgencyHalfLifeMonths: Double = 6
        /// The Hill exponent — higher = a flatter top near the deadline and a sharper drop.
        var urgencyExponent: Double = 2
        /// Finishability is full while `length ≤ fullFraction · hoursLeft`.
        var finishabilityFullFraction: Double = 0.5
        /// Finishability for an unknown length (a neutral middle).
        var neutralFinishability: Double = 0.5
        /// Average weeks per month, for hours-left = weeksLeft · pace.
        var weeksPerMonth: Double = 52.0 / 12.0

        init() {}
    }

    static let constants = Constants()

    // MARK: - Urgency

    /// The smooth urgency ramp 0…1 for `monthsLeft` (clamped at 0; monotonically
    /// non-increasing — more months left means never a larger urgency).
    static func urgency(monthsLeft: Double, c: Constants = constants) -> Double {
        let m = max(0, monthsLeft)
        let ratio = m / c.urgencyHalfLifeMonths
        return 1 / (1 + pow(ratio, c.urgencyExponent))
    }

    // MARK: - Finishability

    /// How comfortably a game fits before the deadline (0…1). Full when the personal length is
    /// at most ~half the hours left, linear down to 0 once it fills the whole window; an
    /// unknown length is the neutral middle. Zero hours left (or none) ⇒ nothing fits.
    static func finishability(personalLengthSeconds: Int?, monthsLeft: Double,
                              pace: PlayPace, c: Constants = constants) -> Double {
        guard let seconds = personalLengthSeconds else { return c.neutralFinishability }
        let hoursLeft = max(0, monthsLeft) * c.weeksPerMonth * pace.hoursPerWeek
        guard hoursLeft > 0 else { return 0 }
        let lengthHours = Double(seconds) / 3600
        let fraction = lengthHours / hoursLeft
        if fraction <= c.finishabilityFullFraction { return 1 }
        if fraction >= 1 { return 0 }
        // Linear falloff from full-fraction (1) to the whole window (0).
        return (1 - fraction) / (1 - c.finishabilityFullFraction)
    }

    // MARK: - The boost term

    /// The additive score term for a PS Plus candidate when a cancellation date is set
    /// (`monthsLeft`). Returns 0 for no date (`nil`) and for a past date (`≤ 0`) — the caller
    /// uses the small constant fallback when no date is set, and shows a "date in the past"
    /// hint in Settings. `personalLengthSeconds` is the owner's personal length (§8), nil when
    /// unknown (most ROMs).
    static func boost(monthsLeft: Double?, personalLengthSeconds: Int?,
                      pace: PlayPace, c: Constants = constants) -> Double {
        guard let months = monthsLeft, months > 0 else { return 0 }
        let u = urgency(monthsLeft: months, c: c)
        let f = finishability(personalLengthSeconds: personalLengthSeconds, monthsLeft: months,
                              pace: pace, c: c)
        return c.maxBoost * u * f
    }

    // MARK: - Months to a picked (month, year)

    /// Fractional months from `now` to the **start** of the picked `(year, month)`. Negative
    /// when the date is already past (used to show the Settings hint and to suppress the boost).
    static func monthsLeft(now: Date, year: Int, month: Int,
                           calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let target = calendar.date(from: comps) else { return 0 }
        let averageMonthSeconds = 365.25 / 12 * 24 * 3600
        return target.timeIntervalSince(now) / averageMonthSeconds
    }

    /// Whether a picked `(year, month)` is already in the past relative to `now` (the Settings
    /// hint condition). A date within the current month is not past.
    static func isPast(now: Date, year: Int, month: Int,
                       calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        guard let target = calendar.date(from: comps),
              let endOfMonth = calendar.date(byAdding: .month, value: 1, to: target) else { return false }
        return endOfMonth <= now
    }

    // MARK: - Reason line

    /// The reason string (PLAN §16): "＋ leaves with PS Plus · ~9 months left · about 22 h for
    /// you", omitting the parts that are unknown (no months when no date; no hours when no
    /// length). `personalLengthSeconds` nil ⇒ the "about … h" clause is dropped.
    static func reason(monthsLeft: Double?, personalLengthSeconds: Int?) -> String {
        var parts = ["leaves with PS Plus"]
        if let months = monthsLeft, months > 0 {
            let rounded = max(1, Int(months.rounded()))
            parts.append("~\(rounded) month\(rounded == 1 ? "" : "s") left")
        }
        if let seconds = personalLengthSeconds {
            let hours = max(1, Int((Double(seconds) / 3600).rounded()))
            parts.append("about \(hours) h for you")
        }
        return "＋ " + parts.joined(separator: " · ")
    }
}
