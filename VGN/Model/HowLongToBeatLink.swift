import Foundation

/// Builds a HowLongToBeat **search** URL by title — a plain link, no API, no
/// scraping (PLAN §5.3/§6.4: "the inspector always has an 'Open on HowLongToBeat'
/// link"). Foundation-only and pure, so it is unit-tested.
enum HowLongToBeatLink {
    static func searchURL(title: String) -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://howlongtobeat.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}
