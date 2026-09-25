import Foundation

/// "Ask Claude" for the **From the vault** row (PLAN §7b, scheduled 2026-09-25): the pure
/// builder that turns the vault shortlist (the top ~10 of ``DiscoverScorer`` for the chosen
/// bracket) into a ``SecondOpinionRequest`` of kind `.vault`, plus the per-session cache key.
///
/// Only what is listed here leaves the app: the tier list (the same taste half as the regular
/// picks) and, per candidate, title, platform/system, source, IGDB genres/themes/year/rating
/// when matched, the time estimate and — for a PS Plus claim with a cancellation date — the
/// months left. An **unmatched** entry is sent as title + system only.
enum DiscoverSecondOpinion {

    /// How many vault entries the shortlist carries ("the top ~10").
    static let shortlistSize = 10

    /// The card/prompt system label: a PS Plus row's `system` is already a VGN platform slug;
    /// a Batocera system maps through ``BatoceraSystems``; otherwise the raw system name.
    static func systemLabel(for entry: RomCatalogEntry) -> String {
        if entry.vaultSource == .psn { return PlatformLabels.short(entry.system) }
        if let slug = BatoceraSystems.platformSlug(for: entry.system) { return PlatformLabels.short(slug) }
        return entry.system
    }

    /// "ROM" / "PS Plus claim" / "owned, not in backlog".
    static func sourceLabel(for entry: RomCatalogEntry) -> String {
        switch entry.vaultSource {
        case .batocera?: return "ROM"
        case .psn?: return entry.owned ? "owned, not in backlog" : "PS Plus claim"
        case .gog?, .delicious?, nil: return "owned, not in backlog"
        }
    }

    /// Whether the entry is matched to IGDB (so its catalogue facts are worth sending).
    static func isMatched(_ entry: RomCatalogEntry) -> Bool {
        entry.igdbID != nil || entry.matchState == .matched
    }

    /// The personal length the vault scorer fits (PLAN §8/§16), in hours (1 decimal), or nil.
    static func estimateHours(for entry: RomCatalogEntry, bracket: TimeBracket?, playStyle: PlayStyle) -> Double? {
        let inputs = EstimateSanity.lengthInputs(
            rushed: nil, main: entry.lengthMainSeconds, completionist: entry.lengthCompleteSeconds,
            sourceIsHLTB: false, dismissed: false)
        let style: PlayStyle = (bracket?.completionist ?? false) ? .completionist : playStyle
        guard let personal = PersonalLength.compute(
            normallyS: inputs.main, completelyS: inputs.completionist, style: style,
            paceFactor: bracket?.paceFactor ?? 1.0) else { return nil }
        return (Double(personal.seconds) / 360).rounded() / 10
    }

    /// Build the vault request. `shortlist` is in the engine (scorer) order, best first.
    static func request(shortlist: [RomCatalogEntry], taste: SecondOpinionTaste,
                        bracket: TimeBracket?, playStyle: PlayStyle,
                        psPlusMonthsLeft: Double?) -> SecondOpinionRequest {
        let items = shortlist.enumerated().map { index, entry -> SecondOpinionRequest.Shortlisted in
            let system = systemLabel(for: entry)
            guard isMatched(entry) else {
                // Unmatched: title + system only (Claude may say it doesn't know it).
                return SecondOpinionRequest.Shortlisted(
                    id: entry.id, title: entry.name, platform: system, format: nil,
                    estimateHours: nil, status: nil, engineRank: index + 1, known: false)
            }
            let traits = entry.traits
            let genres = traits.filter { $0.kind == .genre }.map(\.value)
            let themes = traits.filter { $0.kind == .theme }.map(\.value)
            let isClaim = entry.vaultSource == .psn && !entry.owned
            return SecondOpinionRequest.Shortlisted(
                id: entry.id, title: entry.name, platform: system,
                format: entry.vaultSource == .batocera ? "rom" : nil,
                estimateHours: estimateHours(for: entry, bracket: bracket, playStyle: playStyle),
                status: nil, engineRank: index + 1,
                vaultSource: sourceLabel(for: entry),
                known: true,
                genres: genres.isEmpty ? nil : genres,
                themes: themes.isEmpty ? nil : themes,
                year: entry.releaseYear,
                rating: entry.igdbRating,
                leavesPSPlusInMonths: isClaim ? psPlusMonthsLeft.map { Int($0.rounded()) } : nil)
        }
        return SecondOpinionRequest(
            bracket: bracket?.label ?? "Any length",
            completionist: bracket?.completionist ?? false,
            topRanked: taste.topRanked,
            didntClick: taste.didntClick,
            shortlist: items,
            engineOrdering: shortlist.map(\.id),
            kind: .vault)
    }

    /// The per-session cache key: the shortlist ids (in order) + the bracket.
    struct CacheKey: Hashable, Sendable {
        var shortlist: [Int64]
        var bracket: TimeBracket?
    }
}
