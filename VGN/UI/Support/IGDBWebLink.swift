import Foundation

/// The public IGDB website link, shared by the reconcile link sheet and the Play Next cards
/// (owner 2026-09-20). One URL scheme only — IGDB has no stable public page addressable by the
/// numeric id alone, so a matched game opens its search page keyed on the title (the exact
/// scheme the "Open on IGDB" footer already used).
enum IGDBWebLink {
    /// The IGDB search page for a title (nil for an empty title).
    static func searchURL(name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var comps = URLComponents(string: "https://www.igdb.com/search")
        comps?.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "q", value: trimmed),
        ]
        return comps?.url
    }

    /// The IGDB page for a matched game: nil unless it has an IGDB id, so a manual / unmatched
    /// entry shows no "Open on IGDB" button rather than a dead one.
    static func pageURL(igdbID: Int64?, title: String) -> URL? {
        guard igdbID != nil else { return nil }
        return searchURL(name: title)
    }
}
