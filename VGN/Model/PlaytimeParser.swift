import Foundation

/// Parses free-form playtime input into seconds, and renders seconds back into
/// compact human text. Pure value logic — no dependencies beyond Foundation.
///
/// Accepted inputs (case-insensitive, surrounding whitespace ignored):
/// - `45h`, `45 h`, `45.5h`, French `45,5h`         → hours (may be fractional)
/// - `90m`, `90 min`, `90 mins`, `90 minutes`       → minutes
/// - `2d`, `2 d`, `2 days`                           → days (1 day = 24 h)
/// - `45:30`, `1:05:30`                              → H:MM or H:MM:SS clock form
/// - `1h30`, `1h30m`, `1 h 30 m`, `2h5m`             → combined units
/// - `45`, `45.5`, `45,5`                            → bare number = hours
///
/// Anything else returns `nil` (garbage is rejected, never guessed).
enum PlaytimeParser {

    static let secondsPerMinute: Int = 60
    static let secondsPerHour: Int = 3600
    static let secondsPerDay: Int = 86_400

    // MARK: - Parsing

    /// Parse `input` into a non-negative number of seconds, or `nil` if it is
    /// not a recognisable duration.
    static func seconds(from input: String) -> Int? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }

        // Normalise the decimal comma (French) to a dot, and collapse spaces.
        let s = raw.replacingOccurrences(of: ",", with: ".")

        // 1. Clock form  H:MM  or  H:MM:SS
        if s.contains(":") {
            return parseClock(s)
        }

        // 2. Bare number → hours (accepts fractional)
        if let value = Double(s) {
            guard value >= 0, value.isFinite else { return nil }
            return Int((value * Double(secondsPerHour)).rounded())
        }

        // 3. Unit form (possibly combined): scan number+unit tokens.
        return parseUnits(s)
    }

    private static func parseClock(_ s: String) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        // Each component must be a non-negative integer; minutes/seconds < 60.
        var values: [Int] = []
        for (i, part) in parts.enumerated() {
            guard !part.isEmpty, let n = Int(part), n >= 0 else { return nil }
            if i >= 1 && n >= 60 { return nil }
            values.append(n)
        }
        if values.count == 2 {
            return values[0] * secondsPerHour + values[1] * secondsPerMinute
        } else {
            return values[0] * secondsPerHour + values[1] * secondsPerMinute + values[2]
        }
    }

    /// Scan a run of `<number><unit>` tokens, e.g. `1h30m`, `2d`, `90 min`,
    /// `1h30` (a trailing bare number after `h` is treated as minutes).
    private static func parseUnits(_ s: String) -> Int? {
        var total = 0.0
        var sawUnit = false
        var trailingHoursRemainder = false // true right after an `h` with no minutes yet

        let scalars = Array(s)
        var i = 0
        func skipSpaces() { while i < scalars.count, scalars[i] == " " { i += 1 } }

        while i < scalars.count {
            skipSpaces()
            if i >= scalars.count { break }

            // Read a number (digits + optional single dot).
            let numStart = i
            var sawDigit = false
            var sawDot = false
            while i < scalars.count {
                let c = scalars[i]
                if c.isNumber { sawDigit = true; i += 1 }
                else if c == "." && !sawDot { sawDot = true; i += 1 }
                else { break }
            }
            guard sawDigit else { return nil }
            guard let value = Double(String(scalars[numStart..<i])) else { return nil }

            skipSpaces()

            // Read a unit word (letters).
            let unitStart = i
            while i < scalars.count, scalars[i].isLetter { i += 1 }
            let unit = String(scalars[unitStart..<i])

            switch unit {
            case "d", "day", "days":
                total += value * Double(secondsPerDay)
                sawUnit = true
                trailingHoursRemainder = false
            case "h", "hr", "hrs", "hour", "hours":
                total += value * Double(secondsPerHour)
                sawUnit = true
                trailingHoursRemainder = true
            case "m", "min", "mins", "minute", "minutes":
                total += value * Double(secondsPerMinute)
                sawUnit = true
                trailingHoursRemainder = false
            case "s", "sec", "secs", "second", "seconds":
                total += value
                sawUnit = true
                trailingHoursRemainder = false
            case "":
                // A bare number with no unit. Only valid as the minutes part
                // immediately after an hours token, e.g. "1h30".
                if trailingHoursRemainder {
                    total += value * Double(secondsPerMinute)
                    trailingHoursRemainder = false
                } else {
                    return nil
                }
            default:
                return nil
            }
        }

        guard sawUnit else { return nil }
        return Int(total.rounded())
    }

    // MARK: - Formatting

    /// Compact exact rendering in hours, e.g. `"45 h 30"`, `"45 h"`, `"30 min"`.
    /// Playtime is conventionally shown in hours (not days), so hours are not
    /// rolled up into days even past 24 h ("120 h", never "5 d").
    static func format(seconds: Int) -> String {
        guard seconds > 0 else { return "0 h" }
        let hours = seconds / secondsPerHour
        let minutes = (seconds % secondsPerHour) / secondsPerMinute

        if hours > 0 {
            if minutes > 0 { return "\(hours) h \(minutes)" }
            return "\(hours) h"
        }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds) s"
    }

    /// Approximate rendering for average/estimated figures, e.g. `"≈ 32 h"`.
    /// Rounds to the nearest hour (nearest 10 min under 1 h).
    static func formatApprox(seconds: Int) -> String {
        guard seconds > 0 else { return "≈ 0 h" }
        if seconds < secondsPerHour {
            let minutes = Int((Double(seconds) / 600.0).rounded()) * 10
            if minutes <= 0 { return "≈ 0 h" }
            return "≈ \(minutes) min"
        }
        let hours = Int((Double(seconds) / Double(secondsPerHour)).rounded())
        return "≈ \(hours) h"
    }
}
