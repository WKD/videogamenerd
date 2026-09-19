import Foundation

/// One active-filter chip shown under the toolbar (PLAN §8: "filters … shown as
/// removable chips"). One chip **per value**, grouped by kind and ordered; the
/// first chip of a kind carries the "Kind:" prefix and later chips of the same
/// kind read "or …", so a row reads *"Genre: RPG or Adventure"* while every value
/// stays individually removable — which is exactly the AND-across-kinds /
/// OR-within-a-kind query semantics.
///
/// Foundation-only value type; the view renders it and calls
/// ``LibraryFilterChips`` to remove one or clear all.
struct FilterChip: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case search, genre, decade
        case tier, unrated
        case status, notPlayed, noStatus
        case format, notOwned, multipleCopies
        case playtime, noEstimate, platform

        var label: String {
            switch self {
            case .search: return "Search"
            case .genre: return "Genre"
            case .decade: return "Decade"
            case .tier: return "Tier"
            case .unrated: return "Unrated"
            case .status: return "Status"
            case .notPlayed: return "Not Played"
            case .noStatus: return "Played, No Status"
            case .format: return "Format"
            case .notOwned: return "Not Owned"
            case .multipleCopies: return "Multiple Copies"
            case .playtime: return "Playtime"
            case .noEstimate: return "No Estimate"
            case .platform: return "Platform"
            }
        }

        /// A standalone boolean facet renders as just its label ("Unrated"), with no
        /// "Kind: value" split.
        var isStandalone: Bool {
            switch self {
            case .unrated, .notPlayed, .noStatus, .notOwned, .multipleCopies, .noEstimate: return true
            default: return false
            }
        }
    }

    var kind: Kind
    /// The raw value key used to remove this chip (genre name, "1990", a tier id,
    /// a status/format raw value, a platform slug; empty for the search chip).
    var value: String
    /// Human label for the value ("RPG", "1990s", "S", "Physical", "PS5", the query).
    var valueLabel: String
    /// The first chip of its kind (shows the "Kind:" prefix; later ones read "or …").
    var isGroupLead: Bool

    var id: String { "\(kind.rawValue):\(value)" }

    /// The chip's visible text: "Unrated" for a standalone facet, "Genre: RPG" for a
    /// group lead, "or Adventure" after.
    var text: String {
        if kind.isStandalone { return kind.label }
        return isGroupLead ? "\(kind.label): \(valueLabel)" : "or \(valueLabel)"
    }

    /// Always-full label (accessibility / tooltip): "Genre: RPG", or "Unrated".
    var fullLabel: String { kind.isStandalone ? kind.label : "\(kind.label): \(valueLabel)" }
}

/// Pure builders that turn a ``LibraryFilter`` into chips and apply chip removals.
enum LibraryFilterChips {

    /// The active chips for `filter`, grouped and ordered by kind. `tiers` maps a
    /// tier id → its letter (and sort order); `platformShort` maps a slug → a short
    /// label (defaults to the slug, so the model stays UI-free and testable).
    static func chips(
        for filter: LibraryFilter,
        tiers: [TierInfo] = [],
        platformShort: (String) -> String = { $0 }
    ) -> [FilterChip] {
        var out: [FilterChip] = []

        func add(_ kind: FilterChip.Kind, _ pairs: [(value: String, label: String)]) {
            for (i, pair) in pairs.enumerated() {
                out.append(FilterChip(kind: kind, value: pair.value, valueLabel: pair.label,
                                      isGroupLead: i == 0))
            }
        }

        let text = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { add(.search, [(text, "“\(text)”")]) }

        add(.genre, filter.genres.sorted().map { ($0, $0) })
        add(.decade, filter.decades.sorted().map { (String($0), "\($0)s") })

        let tierByID = Dictionary(tiers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let tierPairs = filter.tierIDs
            .sorted { (tierByID[$0]?.sort ?? .max) < (tierByID[$1]?.sort ?? .max) }
            .map { (String($0), tierByID[$0]?.letter ?? "?") }
        add(.tier, tierPairs)
        if filter.includeUnrated { add(.unrated, [("true", "Unrated")]) }

        let statusPairs = PlayStatus.allCases
            .filter { filter.statuses.contains($0) }
            .map { ($0.rawValue, $0.label) }
        add(.status, statusPairs)
        if filter.includeNotPlayed { add(.notPlayed, [("true", "Not Played")]) }
        if filter.includeNoStatus { add(.noStatus, [("true", "No Status")]) }

        let formatPairs = ProductFormat.allCases
            .filter { filter.formats.contains($0) }
            .map { ($0.rawValue, $0.label) }
        add(.format, formatPairs)
        if filter.includeNotOwned { add(.notOwned, [("true", "Not Owned")]) }
        if filter.multipleCopies { add(.multipleCopies, [("true", "Multiple Copies")]) }

        let playtimePairs = PlaytimeBucket.allCases
            .filter { filter.playtimes.contains($0) }
            .map { ($0.rawValue, $0.label) }
        add(.playtime, playtimePairs)
        if filter.includeNoTimeEstimate { add(.noEstimate, [("true", "No Estimate")]) }

        add(.platform, filter.platforms.sorted().map { ($0, platformShort($0)) })

        return out
    }

    /// A copy of `filter` with `chip`'s value removed (re-runs the query one facet
    /// lighter).
    static func removing(_ chip: FilterChip, from filter: LibraryFilter) -> LibraryFilter {
        var f = filter
        switch chip.kind {
        case .search: f.searchText = ""
        case .genre: f.genres.remove(chip.value)
        case .decade: if let d = Int(chip.value) { f.decades.remove(d) }
        case .tier: if let t = Int64(chip.value) { f.tierIDs.remove(t) }
        case .unrated: f.includeUnrated = false
        case .status: if let s = PlayStatus(rawValue: chip.value) { f.statuses.remove(s) }
        case .notPlayed: f.includeNotPlayed = false
        case .noStatus: f.includeNoStatus = false
        case .format: if let fmt = ProductFormat(rawValue: chip.value) { f.formats.remove(fmt) }
        case .notOwned: f.includeNotOwned = false
        case .multipleCopies: f.multipleCopies = false
        case .playtime: if let b = PlaytimeBucket(rawValue: chip.value) { f.playtimes.remove(b) }
        case .noEstimate: f.includeNoTimeEstimate = false
        case .platform: f.platforms.remove(chip.value)
        }
        return f
    }

    /// A copy of `filter` with **every** facet cleared (search included), keeping the
    /// sidebar scope, sort, direction and weekly play pace ("Clear all"). The pace is
    /// not a facet, so clearing filters must not reset the "By Length" shelf bounds.
    static func cleared(_ filter: LibraryFilter) -> LibraryFilter {
        LibraryFilter(scope: filter.scope, playPace: filter.playPace, playStyle: filter.playStyle,
                      sort: filter.sort, ascending: filter.ascending)
    }
}
