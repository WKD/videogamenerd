import Foundation

/// A compiled URL-prefix allow-list (PLAN §14.1 rule 1 / §13.1 rule 1). Every request
/// an importer makes must match one of these prefixes; anything else is a programming
/// error — it throws ``ImportError/disallowedURL(_:)`` and `assertionFailure`s in DEBUG,
/// so a stray host or a typo can never reach the network in a debug build.
struct ImportAllowList: Sendable {
    let prefixes: [String]

    init(_ prefixes: [String]) {
        self.prefixes = prefixes
    }

    /// GOG's four read-only endpoints (PLAN §14.1). `account/gameDetails` is
    /// deliberately **not** here.
    static let gog = ImportAllowList([
        "https://auth.gog.com/token",
        "https://embed.gog.com/userData.json",
        "https://embed.gog.com/user/data/games",
        "https://embed.gog.com/account/getFilteredProducts",
    ])

    /// PSN's read-only endpoints (PLAN §13.3, exact URL prefixes only): the OAuth
    /// authorize + token calls, the profile, the trophy-titles list, the game list, and
    /// the GraphQL purchases op. Any other host/path is a programming error and traps in
    /// DEBUG (PLAN §13.1 rule 1). Nothing that writes to PSN is here.
    static let psn = ImportAllowList([
        "https://ca.account.sony.com/api/authz/v3/oauth/authorize",
        "https://ca.account.sony.com/api/authz/v3/oauth/token",
        "https://m.np.playstation.com/api/userProfile/v1/internal/users/me/profiles",
        "https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles",
        "https://m.np.playstation.com/api/gamelist/v2/users/me/titles",
        "https://web.np.playstation.com/api/graphql/v1/op",
    ])

    func allows(_ url: URL) -> Bool {
        let s = url.absoluteString
        return prefixes.contains { s.hasPrefix($0) }
    }

    /// Throw (and trap in DEBUG) unless `url` is allow-listed.
    func check(_ url: URL) throws {
        guard allows(url) else {
            assertionFailure("Importer attempted a disallowed URL: \(url.absoluteString)")
            throw ImportError.disallowedURL(url.absoluteString)
        }
    }
}
