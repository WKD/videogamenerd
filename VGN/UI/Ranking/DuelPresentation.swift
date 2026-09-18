import Foundation

/// One side of a duel, flattened from `GameDetail` into just what the two big
/// covers render (PLAN §7). A plain value so header/layout logic is testable
/// with no database.
struct DuelSide: Equatable, Sendable, Identifiable {
    var id: Int64
    var title: String
    var year: Int?
    var platformIDs: [String]
    var coverFile: String?
    var tierLetter: String?
    var tierColorHex: String?
    var tierLabel: String?
    var summary: String?
    var genres: [String]

    init(id: Int64, title: String, year: Int? = nil, platformIDs: [String] = [],
         coverFile: String? = nil, tierLetter: String? = nil, tierColorHex: String? = nil,
         tierLabel: String? = nil, summary: String? = nil, genres: [String] = []) {
        self.id = id
        self.title = title
        self.year = year
        self.platformIDs = platformIDs
        self.coverFile = coverFile
        self.tierLetter = tierLetter
        self.tierColorHex = tierColorHex
        self.tierLabel = tierLabel
        self.summary = summary
        self.genres = genres
    }

    init(detail: GameDetail) {
        self.init(id: detail.id, title: detail.title, year: detail.year,
                  platformIDs: detail.platformIDs, coverFile: detail.coverFile,
                  tierLetter: detail.tierLetter, tierColorHex: detail.tierColorHex,
                  tierLabel: detail.tierLabel, summary: detail.summary, genres: detail.genres)
    }

    init(summary s: GameSummary) {
        self.init(id: s.id, title: s.title, year: s.year, platformIDs: s.platformIDs,
                  coverFile: s.coverFile, tierLetter: s.tierLetter, tierColorHex: s.tierColorHex)
    }
}

/// The current duel, resolved for display: the prompt plus both sides.
struct DuelDisplay: Equatable, Sendable {
    var prompt: DuelPrompt
    var candidate: DuelSide
    var opponent: DuelSide
}

/// Pure header/progress presentation for the Duel view (PLAN §7 — "what is
/// happening in plain words"). No SwiftUI, no store — unit-tested directly.
enum DuelPresentation {

    /// The header line for a prompt, in plain words.
    struct Header: Equatable {
        var kind: DuelPrompt.Kind
        /// The game name to emphasise (placement only; empty otherwise).
        var candidateName: String
        /// Full plain-text header (what a screen reader / test reads).
        var text: String
        /// Placement progress 0…1 for the thin bar (nil for refine/border).
        var progress: Double?
        /// "3 of ~6" for placement, nil otherwise.
        var stepText: String?
    }

    static func header(prompt: DuelPrompt, candidate: DuelSide, opponent: DuelSide) -> Header {
        switch prompt.kind {
        case .placement:
            let tier = candidate.tierLetter ?? "?"
            let step = stepText(prompt)
            return Header(
                kind: .placement,
                candidateName: candidate.title,
                text: "Placing \(candidate.title) in \(tier) · \(step)",
                progress: progress(prompt),
                stepText: step
            )
        case .refine:
            let tier = candidate.tierLetter ?? opponent.tierLetter ?? "?"
            return Header(kind: .refine, candidateName: "",
                          text: "Refine · neighbours in \(tier)",
                          progress: nil, stepText: nil)
        case .border:
            let upper = candidate.tierLetter ?? "?"
            let lower = opponent.tierLetter ?? "?"
            return Header(kind: .border, candidateName: "",
                          text: "Border duel · bottom of \(upper) vs top of \(lower)",
                          progress: nil, stepText: nil)
        }
    }

    /// "3 of ~6": 1-based current comparison of the estimated total.
    static func stepText(_ prompt: DuelPrompt) -> String {
        let total = max(1, prompt.estimatedTotal)
        let current = min(prompt.comparisonsMade + 1, total)
        return "\(current) of ~\(total)"
    }

    /// Placement progress fraction 0…1.
    static func progress(_ prompt: DuelPrompt) -> Double {
        let total = max(1, prompt.estimatedTotal)
        return min(1, Double(prompt.comparisonsMade) / Double(total))
    }

    /// The "n games left to place" pill copy (PLAN §7).
    static func queueText(_ count: Int) -> String {
        count == 1 ? "1 game left to place" : "\(count) games left to place"
    }
}

// MARK: - Keyboard routing (PLAN §7, §8)

/// A physical key the Duel view can receive.
enum DuelKeyInput: Equatable, Sendable {
    case left        // ←  → candidate wins
    case right       // →  → opponent wins
    case down        // ↓  → skip
    case undo        // ⌘Z
    case peek        // space → toggle details popover
    case accept      // ↩ (border suggestion card)
    case dismiss     // esc (border suggestion card)
}

/// The intent a key maps to. `ignored` = the view should not consume it.
enum DuelIntent: Equatable, Sendable {
    case pickCandidate
    case pickOpponent
    case skip
    case undo
    case togglePeek
    case acceptBorder
    case dismissBorder
    case ignored
}

/// Pure key → intent routing. A border **suggestion card** (shown after a border
/// duel) swaps the meaning of `↩`/`esc` to Accept/Dismiss and suppresses the
/// pick/skip keys, so an answer can't leak past the decision (PLAN §7).
enum DuelKeyRouter {
    static func intent(for key: DuelKeyInput, showingBorderSuggestion: Bool) -> DuelIntent {
        if showingBorderSuggestion {
            switch key {
            case .accept: return .acceptBorder
            case .dismiss: return .dismissBorder
            case .undo: return .undo
            default: return .ignored
            }
        }
        switch key {
        case .left: return .pickCandidate
        case .right: return .pickOpponent
        case .down: return .skip
        case .undo: return .undo
        case .peek: return .togglePeek
        case .accept, .dismiss: return .ignored
        }
    }
}
