import Foundation

/// The injected PSN OAuth configuration (PLAN §13.1 rule 5). Sony has no public API; this
/// uses the endpoints and the **public** mobile-app OAuth client that every open-source
/// PSN client ships (see ``PSNAuthConfiguration/mobileApp`` — ported from
/// `achievements-app/psn-api`). Everything is injected so tests use a fake configuration,
/// **never** the real values, and a live request is never made in this lane (S0).
///
/// Two sign-in mechanisms are modelled for the later UI (WKWebView) lane, both landing on
/// an **NPSSO** token that this actor exchanges for OAuth tokens (PLAN §13.1 rule 5):
///  1. reading the `npsso` cookie after a web login in a `WKWebView`
///     (``loginURL`` + ``npssoCookieName`` / ``npssoCookieDomain`` + ``navigationPolicy``);
///  2. a pasted NPSSO string (validated for shape only — ``isPlausibleNPSSO(_:)``).
struct PSNAuthConfiguration: Sendable, Equatable {
    /// `…/authorize` — exchanged (with `Cookie: npsso=…`) for the authorization code.
    var authorizationEndpoint: URL
    /// `…/token` — exchanges the code / a refresh token for OAuth tokens.
    var tokenEndpoint: URL
    /// The mobile-app OAuth `client_id`.
    var clientID: String
    /// The full `Authorization: Basic …` header value for the token endpoint (the
    /// mobile-app `client_id:client_secret`, base64). Public, shipped by every client.
    var tokenBasicAuth: String
    /// The app's custom-scheme redirect URI the authorization code rides on.
    var redirectURI: String
    /// OAuth scope requested at authorize + refresh.
    var scope: String
    /// `access_type` — `offline` so a refresh token is issued.
    var accessType: String

    /// The Sony sign-in page the WKWebView loads first. After the user logs in, the
    /// `npsso` cookie is present in the web view's cookie store (route 1).
    /// ASSUMPTION(S0): verify the exact sign-in URL and that it yields the `npsso`
    /// cookie at S1.
    var loginURL: URL
    /// The cookie the WKWebView bridge reads after login (route 1).
    var npssoCookieName: String
    /// The domain the `npsso` cookie is set on. ASSUMPTION(S0): verify at S1.
    var npssoCookieDomain: String
    /// The JSON endpoint that returns `{"npsso":"…"}` once signed in — the fallback way
    /// to read the NPSSO if the cookie store cannot be read directly (route 1 helper).
    var ssoCookieEndpoint: URL
    /// Hosts the login WKWebView may navigate to on the **main frame** (PLAN §13.1). A
    /// captcha host Sony's page loads is added by the UI lane, like GOG.
    var allowedNavigationHosts: [String]

    init(authorizationEndpoint: URL,
         tokenEndpoint: URL,
         clientID: String,
         tokenBasicAuth: String,
         redirectURI: String,
         scope: String,
         accessType: String = "offline",
         loginURL: URL,
         npssoCookieName: String = "npsso",
         npssoCookieDomain: String,
         ssoCookieEndpoint: URL,
         allowedNavigationHosts: [String]) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.tokenBasicAuth = tokenBasicAuth
        self.redirectURI = redirectURI
        self.scope = scope
        self.accessType = accessType
        self.loginURL = loginURL
        self.npssoCookieName = npssoCookieName
        self.npssoCookieDomain = npssoCookieDomain
        self.ssoCookieEndpoint = ssoCookieEndpoint
        self.allowedNavigationHosts = allowedNavigationHosts
    }

    /// The GET `…/authorize` URL used, with a `Cookie: npsso=…` header, to obtain the
    /// authorization code (PLAN §13.3, ported from `psn-api`
    /// `exchangeNpssoForAccessCode`). Its query is the mobile app's exactly.
    var authorizationURL: URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "access_type", value: accessType),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
        ]
        return components.url!
    }

    /// Shape-only validation of a pasted / cookie NPSSO (route 2 + a guard on route 1).
    /// The value never leaves the device and is never logged; this only rejects an
    /// obviously-wrong paste before a request is attempted.
    /// ASSUMPTION(S0): the NPSSO is a URL-safe token of ~64 characters — confirm the
    /// exact length/charset at S1.
    static func isPlausibleNPSSO(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...128).contains(token.count) else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        return token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// What the login WKWebView should do with one navigation (PLAN §13.1 — the WebView is
/// restricted to Sony's login hosts). Pure, so the bridge stays a thin shell and the rule
/// is fully unit-tested.
enum PSNLoginNavigation: Sendable, Equatable {
    case allow
    case block
}

/// The pure navigation policy for the login WKWebView (PLAN §13.1). The **main-frame-only
/// rule**: a *main-frame* navigation is allowed only to one of the configured Sony hosts
/// (anything else — an outbound link, a tracker, a phishing redirect — is blocked); a
/// *sub-frame* load (captcha, embedded resources Sony's own page pulls in) is always
/// allowed, because blocking it would break the login page.
struct PSNLoginNavigationPolicy: Sendable, Equatable {
    let allowedHosts: [String]

    init(allowedHosts: [String]) { self.allowedHosts = allowedHosts }

    func decision(for url: URL, isMainFrame: Bool) -> PSNLoginNavigation {
        // The app's own custom-scheme redirect is not an http(s) navigation to block —
        // the bridge intercepts it before this; treat a non-http scheme as allow so the
        // bridge sees it.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .allow
        }
        guard isMainFrame else { return .allow }   // sub-frame resources always load
        guard let host = url.host?.lowercased() else { return .block }
        return allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
            ? .allow : .block
    }
}
