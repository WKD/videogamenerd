import Foundation

/// The injected GOG OAuth configuration (PLAN §14.1 — the sign-in route is the owner's
/// decision; **route (a), authorization-code**, was chosen at G1). Client credentials
/// are injected (see ``GOGAuthConfiguration/galaxy``) so nothing is hard-wired here, and
/// tests use a fake configuration, never the real Galaxy values.
struct GOGAuthConfiguration: Sendable, Equatable {
    var clientID: String
    var clientSecret: String
    /// Where GOG redirects after a successful login; the `code` rides on this URL.
    var redirectURI: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    /// The WKWebView `layout` GOG expects for the desktop-client login flow.
    var layout: String
    /// Hosts the login WebView may navigate to (PLAN §14.1). Configurable because GOG's
    /// page can pull in a captcha host that is not known ahead of time.
    var allowedNavigationHosts: [String]

    init(clientID: String,
         clientSecret: String,
         redirectURI: String = "https://embed.gog.com/on_login_success?origin=client",
         authorizationEndpoint: URL = URL(string: "https://auth.gog.com/auth")!,
         tokenEndpoint: URL = URL(string: "https://auth.gog.com/token")!,
         layout: String = "client2",
         allowedNavigationHosts: [String] = ["auth.gog.com", "login.gog.com",
                                             "www.gog.com", "gog.com"]) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.layout = layout
        self.allowedNavigationHosts = allowedNavigationHosts
    }

    /// The URL the login WebView loads first (PLAN §14.1 route a). The UI (WKWebView
    /// bridge) lane loads this, watches navigation, and hands the extracted `code` to
    /// ``GOGAuth/completeSignIn(code:)``.
    var authorizationURL: URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "layout", value: layout),
        ]
        return components.url!
    }
}

/// What the login WebView's current URL means (PLAN §14.1). Pure — the bridge feeds
/// each navigation URL to ``GOGAuthRedirectParser`` and acts on the outcome.
enum GOGAuthRedirectOutcome: Sendable, Equatable {
    /// The success redirect carrying the authorization `code`.
    case code(String)
    /// The user cancelled / denied access.
    case cancelled
    /// GOG reported an error (its description, already safe to show).
    case failed(String)
    /// Not the redirect we are waiting for — keep loading.
    case notARedirect
}

/// Recognises the GOG login success/failure redirect and extracts the `code`
/// (PLAN §14.1). Pure and `Sendable`, so the WebView bridge stays a thin shell and the
/// parsing is fully unit-tested.
struct GOGAuthRedirectParser: Sendable {
    /// The prefix the success redirect starts with (scheme + host + path of `redirectURI`).
    let redirectPrefix: String

    init(redirectURI: String) {
        // Compare on scheme+host+path only, ignoring the query GOG appends.
        if let components = URLComponents(string: redirectURI),
           let scheme = components.scheme, let host = components.host {
            self.redirectPrefix = "\(scheme)://\(host)\(components.path)"
        } else {
            self.redirectPrefix = redirectURI
        }
    }

    func parse(_ url: URL) -> GOGAuthRedirectOutcome {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, let host = components.host else {
            return .notARedirect
        }
        let base = "\(scheme)://\(host)\(components.path)"
        guard base == redirectPrefix else { return .notARedirect }

        let items = components.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
            return .code(code)
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" || error == "cancel" { return .cancelled }
            let description = items.first(where: { $0.name == "error_description" })?.value ?? error
            return .failed(description)
        }
        // Right URL, no code and no error yet — treat as an intermediate step.
        return .notARedirect
    }
}
