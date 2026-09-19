import Foundation

/// Display facts about a ranked exemplar a reason points at (its title + tier), so
/// the formatter can write "like **Elden Ring** (S)". Loaded by the model from the
/// library for every exemplar id a result cites.
struct ExemplarInfo: Sendable, Hashable {
    var title: String
    var tierLetter: String?

    init(title: String, tierLetter: String? = nil) {
        self.title = title
        self.tierLetter = tierLetter
    }
}

/// Turns the engine's structured ``PlayNextReason`` *values* into the plain-words
/// sentences the Play Next view shows (PLAN §7b — "the engine emits values; the UI
/// writes the sentences"). Pure and Foundation-only, so every case is unit-tested.
///
/// Bold spans are written as Markdown `**…**`; the view renders them with
/// `AttributedString(markdown:)`.
enum PlayNextReasonFormatter {

    /// At most this many reasons are shown per suggestion (PLAN §7b), taken in the
    /// engine's own order — the contributions that carried the score come first.
    static let maxReasons = 3

    /// The sentences for a suggestion, capped and in score-contribution order.
    static func sentences(
        for suggestion: PlayNextSuggestion,
        exemplars: [Int64: ExemplarInfo],
        bracket: TimeBracket,
        limit: Int = maxReasons
    ) -> [String] {
        suggestion.reasons.prefix(limit).map { sentence(for: $0, exemplars: exemplars, bracket: bracket) }
    }

    /// Sentences for a bare reason list with **no** time bracket (Batocera "Discover",
    /// PLAN §15 — a catalogue entry rarely has a knowable length, so Discover never produces
    /// a time reason). A nominal bracket is passed for the switch's exhaustiveness only.
    static func sentences(
        for reasons: [PlayNextReason],
        exemplars: [Int64: ExemplarInfo],
        limit: Int = maxReasons
    ) -> [String] {
        let nominal = TimeBracket(shelf: .evening)
        return reasons.prefix(limit).map { sentence(for: $0, exemplars: exemplars, bracket: nominal) }
    }

    /// One reason as a sentence.
    static func sentence(
        for reason: PlayNextReason,
        exemplars: [Int64: ExemplarInfo],
        bracket: TimeBracket
    ) -> String {
        switch reason {
        case let .sharedFranchise(value, with):
            return "In the \(value) series — you ranked \(exemplar(with, exemplars))"
        case let .sharedSeries(value, with):
            return "Part of \(value), like \(exemplar(with, exemplars))"
        case let .sameDeveloper(name, exemplar: e):
            return "From \(name), like \(exemplar(e, exemplars))"
        case let .similarTo(e):
            return "Similar to \(exemplar(e, exemplars))"
        case let .traitAffinity(kind, value, lift):
            let phrase = traitPhrase(kind: kind, value: value)
            return lift > 0 ? "You rate \(phrase) highly" : "Not usually your thing (\(phrase))"
        case let .fitsBracket(estimateSeconds, _):
            // The estimate is the personal length at the owner's play style ("for you").
            return "\(PlaytimeParser.formatApprox(seconds: estimateSeconds)) for you — fits '\(bracket.label)'"
        case let .remainingTime(remainingSeconds):
            return "about \(approxLeft(remainingSeconds)) left"
        case let .crowdRated(rating, _):
            return "Well regarded (IGDB \(Int(rating.rounded())))"
        case .noMetadata:
            return "No metadata — matched on length only"
        case .weakEvidence:
            return "Little to go on yet"
        case .leavesWithSubscription:
            return "Leaves with PS Plus"
        case let .leavesWithSubscriptionDeadline(monthsLeft, personalLengthSeconds):
            return PSPlusDeadlineBoost.reason(monthsLeft: monthsLeft.map(Double.init),
                                              personalLengthSeconds: personalLengthSeconds)
        case .batoceraFavourite:
            return "★ a favourite on your Batocera"
        case .batoceraFavouritePinned:
            return "★ your favourite"
        }
    }

    // MARK: - Pieces

    /// "**Title** (S)" for a cited exemplar, gracefully degrading when it is missing.
    private static func exemplar(_ id: Int64, _ exemplars: [Int64: ExemplarInfo]) -> String {
        guard let info = exemplars[id] else { return "a game you ranked" }
        if let tier = info.tierLetter, !tier.isEmpty {
            return "**\(info.title)** (\(tier))"
        }
        return "**\(info.title)**"
    }

    /// A natural noun phrase for a trait affinity, e.g. "stealth games", "PS2 games",
    /// "the 2010s".
    static func traitPhrase(kind: GameTraitKind, value: String) -> String {
        switch kind {
        case .genre, .theme, .keyword, .mode:
            return "\(value) games"
        case .platform:
            return "\(PlatformLabels.short(value)) games"
        case .decade:
            return "the \(value)s"
        case .perspective, .franchise, .series, .developer, .similar:
            return value
        }
    }

    /// "12 h" / "40 min" for a remaining-time reason.
    private static func approxLeft(_ seconds: Int) -> String {
        if seconds < PlaytimeParser.secondsPerHour {
            let minutes = max(10, Int((Double(seconds) / 600).rounded()) * 10)
            return "\(minutes) min"
        }
        let hours = Int((Double(seconds) / Double(PlaytimeParser.secondsPerHour)).rounded())
        return "\(hours) h"
    }
}
