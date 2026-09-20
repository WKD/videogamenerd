import Foundation

/// Pure display maths for the import **matching** phase (coordinator 2026-09-20): the
/// determinate progress fraction, the "Matching 137 of 412 · Elden Ring" label, and an
/// estimated-time-remaining string derived from the observed per-item rate. Foundation only,
/// no clock of its own (elapsed seconds are passed in), so every rule is unit-testable with no
/// wall-clock assertion.
enum ImportMatchProgress {

    /// ETA is shown only once at least this many items are done (before that the rate is too
    /// noisy — the coordinator's "hide it when unstable").
    static let minItemsForETA = 10

    /// "Matching N of M" plus " · <title>" when a current title is known.
    static func label(completed: Int, total: Int?, title: String = "") -> String {
        var line: String
        if let total, total > 0 {
            line = "Matching \(min(completed, total)) of \(total)"
        } else {
            line = "Matching…"
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { line += " · \(trimmed)" }
        return line
    }

    /// The 0…1 progress fraction, or nil when the total is unknown (an indeterminate bar).
    static func fraction(completed: Int, total: Int?) -> Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// "about 3 min left" from the observed rate, or nil to hide it: before ``minItemsForETA``
    /// items are done, when the total is unknown, or when there is no elapsed time to measure a
    /// rate from. Uses the mean per-item time so far — good enough for a rate-limited pass.
    static func etaText(completed: Int, total: Int?, elapsedSeconds: Double,
                        minItems: Int = minItemsForETA) -> String? {
        guard let total, total > completed, completed >= minItems, elapsedSeconds > 0 else { return nil }
        let perItem = elapsedSeconds / Double(completed)
        let remaining = Double(total - completed) * perItem
        let human = humanDuration(remaining)
        return human == "under a minute" ? "under a minute left" : "about \(human) left"
    }

    /// A coarse, friendly duration ("under a minute", "3 min", "1 h 5 min").
    static func humanDuration(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 45 { return "under a minute" }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rem = minutes % 60
        return rem == 0 ? "\(hours) h" : "\(hours) h \(rem) min"
    }
}
