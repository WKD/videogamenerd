import Foundation

/// The owner's optional **"I plan to leave PS Plus around [month year]"** setting (PLAN §16),
/// persisted in ``AppPreferences/defaults`` (never `UserDefaults.standard` under the test host).
/// Settings ▸ PlayStation writes it; both Play Next scorers — the regular picks and "From the
/// vault" — read the current months-left from it, so a change reaches both.
///
/// Clearing it (setting ``picked`` to nil) removes every effect. A date in the past shows a
/// gentle Settings hint (``isPast``) and is treated as "no active deadline" for scoring
/// (``monthsLeft`` returns nil), so a stale date falls back to the constant "Prioritise PS Plus
/// games" boost rather than silently switching the ramp off.
struct PSPlusDeadlinePreferences: Sendable {
    /// `UserDefaults` is internally synchronised but not `Sendable`-annotated.
    nonisolated(unsafe) let defaults: UserDefaults
    private let yearKey = "psPlus.deadline.year"
    private let monthKey = "psPlus.deadline.month"

    init(defaults: UserDefaults = AppPreferences.defaults) { self.defaults = defaults }

    /// A change to the deadline posts this, so an open Play Next / "From the vault" recomputes.
    static let didChange = Notification.Name("vgn.psPlusDeadlineDidChange")

    /// The picked `(year, month)`, or nil when unset.
    var picked: (year: Int, month: Int)? {
        get {
            guard defaults.object(forKey: yearKey) != nil,
                  defaults.object(forKey: monthKey) != nil else { return nil }
            let year = defaults.integer(forKey: yearKey)
            let month = defaults.integer(forKey: monthKey)
            guard year > 0, (1...12).contains(month) else { return nil }
            return (year, month)
        }
        nonmutating set {
            if let value = newValue {
                defaults.set(value.year, forKey: yearKey)
                defaults.set(value.month, forKey: monthKey)
            } else {
                defaults.removeObject(forKey: yearKey)
                defaults.removeObject(forKey: monthKey)
            }
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// Fractional months from `now` to the picked date **for scoring**: nil when unset or in the
    /// past (so the constant fallback applies), else the positive months-left the ramp uses.
    func monthsLeft(now: Date = Date()) -> Double? {
        guard let picked else { return nil }
        let months = PSPlusDeadlineBoost.monthsLeft(now: now, year: picked.year, month: picked.month)
        return months > 0 ? months : nil
    }

    /// Whether the picked date is already in the past (the Settings hint), false when unset.
    func isPast(now: Date = Date()) -> Bool {
        guard let picked else { return false }
        return PSPlusDeadlineBoost.isPast(now: now, year: picked.year, month: picked.month)
    }
}
