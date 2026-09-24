import Foundation

/// The leave-one-out taste-model self-check (PLAN §7b "It checks itself"). Reports
/// how well the affinity/link model recovers the user's own ranking (Spearman ρ),
/// and a plain verdict the Play Next view shows.
struct TasteBacktestResult: Hashable, Sendable {
    /// Spearman rank correlation between predicted and actual scores, `nil` when
    /// there was not enough data to compute one.
    var spearman: Double?
    /// How many ranked games the backtest ran over.
    var sampleCount: Int
    var verdict: TasteVerdict
    /// The same backtest run **without** the games first played before a chosen year (PLAN
    /// §7b "Helping me judge") — nil when no cutoff was asked for. Only games with a known
    /// first-played date are removed; the rest stay in.
    var cutoff: Cutoff? = nil

    struct Cutoff: Hashable, Sendable {
        /// Games first played strictly before this year are left out.
        var year: Int
        /// ρ over the remaining games, nil when not computable (too few / constant).
        var spearman: Double?
        var sampleCount: Int
        /// How many ranked games the cutoff removed.
        var excludedCount: Int
    }

    /// "ρ = 0.52" (or "ρ = —" when not computable) — the headline number.
    var rhoText: String { Self.format(spearman) }

    /// "ρ = 0.52 · without pre-1995 games: 0.41" — the drift line the owner reads; just the
    /// headline when no cutoff is set.
    var driftLine: String {
        guard let cutoff else { return rhoText }
        return "\(rhoText) · without pre-\(cutoff.year) games: \(Self.number(cutoff.spearman))"
    }

    static func format(_ rho: Double?) -> String { "ρ = " + number(rho) }

    static func number(_ rho: Double?) -> String {
        guard let rho else { return "—" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rho)
    }
}

/// The Play Next view's model-quality badge (PLAN §7b).
enum TasteVerdict: String, Hashable, Sendable, Codable {
    /// The model recovers the ranking well.
    case good
    /// Some signal, but noisy.
    case rough
    /// Too few ranked games to judge — lean on the crowd prior.
    case notEnoughData

    var label: String {
        switch self {
        case .good: return "good"
        case .rough: return "rough"
        case .notEnoughData: return "not enough data"
        }
    }
}
