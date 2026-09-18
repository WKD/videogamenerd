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
