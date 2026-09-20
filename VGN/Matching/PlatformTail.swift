import Foundation

/// Drops a trailing PlayStation platform tail that Sony appends to a store title, for
/// MATCHING / search-prefill only (PLAN §13.3 / §5.1). Pure Foundation, so it is shared by
/// the PSN importer (`PSNMapping.cleanMatchTitle`) and the reconcile "Link to IGDB…" prefill
/// (`IGDBLinkQuery`) — a cross-gen twin like "… PS4 & PS5" then searches for the same IGDB
/// game as its sibling, and the sheet is not left with an empty result.
///
/// Deliberately conservative: it strips only a **trailing** run of recognised platform tokens
/// (optionally parenthesised, optionally after "for"), never the interior of a title, and
/// never the whole string — a title that *is* a platform token is left alone. Counter-cases
/// like "Persona 5", "NBA 2K21", "Katamari Damacy" carry no platform token and are untouched.
enum PlatformTail {
    static func drop(_ title: String) -> String {
        // One platform token: PS1–PS5, PS Vita, PSVR(2), PlayStation 4/5, PlayStation Vita.
        let tok = #"(?:ps\s?[1-5]|ps\s?vita|psvr\s?2?|playstation\s?[1-5]|playstation\s?vita)"#
        // A parenthesised tail: " (PS4)", " (PS4/PS5)".
        let paren = #"\s*\((?:"# + tok + #")(?:\s*[,/&]\s*(?:"# + tok + #"))*\)\s*$"#
        // A bare tail: " PS4 & PS5", " for PS4", optionally joined by & , / and.
        let bare = #"\s+(?:for\s+)?(?:"# + tok + #")(?:\s*(?:&|,|/|and)\s*(?:"# + tok + #"))*\s*$"#
        for pattern in [paren, bare] {
            if let range = title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let stripped = title.replacingCharacters(in: range, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Never strip the whole title away (a title that is only a platform token stays).
                if !stripped.isEmpty { return stripped }
            }
        }
        return title
    }
}
