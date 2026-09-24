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

        // MARK: "From the vault" only (PLAN §7b "Ask Claude for From the vault") — all nil
        // for a regular backlog pick, so the regular prompt is byte-for-byte unchanged.

        /// Where the candidate sits: "ROM", "PS Plus claim" or "owned, not in backlog".
        var vaultSource: String? = nil
        /// false = an unmatched entry, sent with title + system only (Claude may say it
        /// doesn't know the game). nil for a regular pick.
        var known: Bool? = nil
        /// IGDB genres / themes when matched.
        var genres: [String]? = nil
        var themes: [String]? = nil
        /// Release year when matched.
        var year: Int? = nil
        /// IGDB crowd rating (0…100) when matched.
        var rating: Double? = nil
        /// For a PS Plus claim with a cancellation date: whole months until it leaves.
        var leavesPSPlusInMonths: Int? = nil
    }

    /// Which shortlist the request is about: the regular backlog picks, or the "From the
    /// vault" row (ROMs / PS Plus claims / owned-not-backlog games — PLAN §16).
    enum Kind: String, Codable, Hashable, Sendable {
        case backlog
        case vault
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
    /// Regular picks (default) or the vault row; selects the prompt variant.
    var kind: Kind = .backlog
}

/// The taste half of a second-opinion request (the tier list + "didn't click"), shared by
/// the regular picks and the "From the vault" variant so both tell Claude the same thing.
struct SecondOpinionTaste: Sendable, Hashable {
    var topRanked: [SecondOpinionRequest.RankedTitle]
    var didntClick: [SecondOpinionRequest.DislikedTitle]

    static let empty = SecondOpinionTaste(topRanked: [], didntClick: [])
}
