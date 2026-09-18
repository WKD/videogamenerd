import Foundation

/// The exact, minimal payload that may leave the app for the "Ask Claude" second
/// opinion (PLAN §7b). A plain `Codable` value — no library dump: only the tier
/// list (top ~60 by rank + the D–F "didn't click" titles), the shortlisted
/// candidates, the chosen bracket, and the engine's own ordering.
///
/// The store builds it; a later UI wave feeds it to the shared `claude` CLI runner
/// (the recognition lane is building that runner). Nothing here spawns a process.
struct SecondOpinionRequest: Codable, Hashable, Sendable {
    /// A ranked game the user placed high (top ~60), with its tier letter.
    struct RankedTitle: Codable, Hashable, Sendable {
        var title: String
        var tier: String
        var globalPosition: Int
    }
    /// A game the user ranked D–F ("didn't click").
    struct DislikedTitle: Codable, Hashable, Sendable {
        var title: String
        var tier: String
    }
    /// One shortlisted candidate (what Claude re-ranks; it may never add ids).
    struct Shortlisted: Codable, Hashable, Sendable {
        var id: Int64
        var title: String
        var platform: String?
        var format: String?
        var estimateHours: Double?
        var status: String?
        /// The engine's own rank of this candidate (1 = the engine's hero).
        var engineRank: Int
    }

    var bracket: String
    var completionist: Bool
    /// Top ranked games (best first), capped (~60).
    var topRanked: [RankedTitle]
    /// The D–F tiers as "didn't click".
    var didntClick: [DislikedTitle]
    /// The 5–15 shortlisted candidates in engine order.
    var shortlist: [Shortlisted]
    /// The engine's ordering as candidate ids (hero first) — redundant with
    /// `shortlist[].engineRank`, kept explicit for the prompt.
    var engineOrdering: [Int64]
}
