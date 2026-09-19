import Foundation

extension PSNAuthConfiguration {
    /// The PlayStation **mobile-app** OAuth values, shipped by every open-source PSN
    /// client (they are Sony's own client values, not the owner's secrets). Ported from
    /// `achievements-app/psn-api` (TypeScript, MIT), commit
    /// `1e9d9a806fcd884a4ddee8086bfe92594611da9f` (2026-08-15) — see `docs/psn-import.md`
    /// for the exact files and every disagreement between the reference clients.
    ///
    /// Cross-checked against `isFakeAccount/psnawp` (Python) and
    /// `andshrew/PlayStation-Trophies` (endpoint notes).
    ///
    /// - `client_id` and the Basic auth (`client_id:client_secret`, base64) are the
    ///   mobile app's; `tokenBasicAuth` decodes to `09515159-…:ucPjka5tntB2KqsP`.
    /// - The redirect URI is the app's custom scheme `com.scee.psxandroid.scecompcall://redirect`.
    /// - Scope is `psn:mobile.v2.core psn:clientapp`.
    ///
    /// ASSUMPTION(S0): these are still the current mobile-app values and Sony's endpoints
    /// still accept them — **verified at S1** (test-account sign-in + the two token calls).
    /// Tests must use a fake configuration (``fake``-style), never this one.
    static let mobileApp = PSNAuthConfiguration(
        authorizationEndpoint: URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/authorize")!,
        tokenEndpoint: URL(string: "https://ca.account.sony.com/api/authz/v3/oauth/token")!,
        clientID: "09515159-7237-4370-9b40-3806e67c0891",
        // Base64 of `09515159-7237-4370-9b40-3806e67c0891:ucPjka5tntB2KqsP`.
        tokenBasicAuth: "Basic MDk1MTUxNTktNzIzNy00MzcwLTliNDAtMzgwNmU2N2MwODkxOnVjUGprYTV0bnRCMktxc1A=",
        redirectURI: "com.scee.psxandroid.scecompcall://redirect",
        scope: "psn:mobile.v2.core psn:clientapp",
        accessType: "offline",
        // ASSUMPTION(S0): the sign-in page + npsso cookie domain — verified at S1.
        loginURL: URL(string: "https://my.playstation.com/")!,
        npssoCookieName: "npsso",
        npssoCookieDomain: "ca.account.sony.com",
        ssoCookieEndpoint: URL(string: "https://ca.account.sony.com/api/v1/ssocookie")!,
        // Sony sign-in + the account hosts the login flow touches (a captcha host the page
        // pulls in is added by the UI lane, like GOG). ASSUMPTION(S0): confirm at S1.
        allowedNavigationHosts: [
            "playstation.com",
            "sony.com",
            "sonyentertainmentnetwork.com",
            "account.sony.com",
            "ca.account.sony.com",
            "my.account.sony.com",
        ]
    )
}
