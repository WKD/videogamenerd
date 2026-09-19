import SwiftUI
import WebKit

/// The pure navigation decision for the GOG login WebView (PLAN §14.1). All the logic
/// lives here so the `NSViewRepresentable` stays a thin shell and the rules are fully
/// unit-tested: run every URL through ``GOGAuthRedirectParser`` **first** (the success
/// redirect host `embed.gog.com` is not on the browse allow-list, so it must be caught
/// before the host check), and only a non-redirect URL is checked against the allowed
/// login hosts. The extracted `code` is returned but **never** logged or shown.
struct GOGLoginNavigationPolicy: Sendable {
    let parser: GOGAuthRedirectParser
    let allowedHosts: [String]

    /// What the WebView should do with a URL it is about to load.
    enum Decision: Sendable, Equatable {
        /// Let the navigation proceed (a login host we trust).
        case allow
        /// Cancel: the host is not on the allow-list (nothing is opened externally).
        case block(host: String)
        /// The success redirect — cancel, close the sheet, exchange this `code`.
        case completed(code: String)
        /// GOG reported an error — cancel and surface `reason`.
        case failed(reason: String)
        /// The user cancelled / denied — cancel and close.
        case cancelled

        /// A description safe to log: the authorization `code` is **never** included
        /// (PLAN §14.1 — "the code is never logged").
        var logDescription: String {
            switch self {
            case .allow: return "allow"
            case .block(let host): return "block(\(host))"
            case .completed: return "completed"
            case .failed(let reason): return "failed(\(reason))"
            case .cancelled: return "cancelled"
            }
        }
    }

    func decide(url: URL) -> Decision {
        // The redirect parser runs first (PLAN §14.1): its success/error host is off the
        // browse allow-list, so it would otherwise be blocked before we read the code.
        switch parser.parse(url) {
        case .code(let code): return .completed(code: code)
        case .failed(let reason): return .failed(reason: reason)
        case .cancelled: return .cancelled
        case .notARedirect: break
        }
        guard let host = url.host, !host.isEmpty else { return .block(host: url.absoluteString) }
        return Self.isAllowed(host: host, in: allowedHosts) ? .allow : .block(host: host)
    }

    /// A host is allowed when it exactly matches a listed host or is a subdomain of one
    /// (so `auth.gog.com` matches, and `embed.gog.com` matches the bare `gog.com`).
    static func isAllowed(host: String, in allowed: [String]) -> Bool {
        let h = host.lowercased()
        return allowed.contains { entry in
            let e = entry.lowercased()
            return h == e || h.hasSuffix("." + e)
        }
    }
}

// MARK: - Login sheet

/// GOG's login page in a **non-persistent** `WKWebView` (PLAN §14.1): VGN never sees the
/// password; a `WKNavigationDelegate` cancels off-allow-list navigation, intercepts the
/// success redirect before it renders, and hands the `code` to ``completeSignIn``. The
/// current host is shown read-only (anti-phishing); the `code` never reaches the UI.
///
/// `import WebKit` is confined to this one file.
struct GOGLoginSheet: View {
    let authorizationURL: URL
    let policy: GOGLoginNavigationPolicy
    /// Called with the extracted authorization code (never logged). Async so the caller
    /// can exchange it and then dismiss.
    let completeSignIn: (String) -> Void
    let onCancel: () -> Void

    @State private var currentHost: String = ""
    @State private var isLoading = true
    @State private var blockedHost: String?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GOGLoginWebView(
                url: authorizationURL,
                policy: policy,
                onHostChange: { currentHost = $0 },
                onLoadingChange: { isLoading = $0 },
                onBlocked: { blockedHost = $0 },
                onCompleted: { code in completeSignIn(code) },
                onFailed: { failure = $0 },
                onCancelled: onCancel
            )
            .frame(minWidth: 520, minHeight: 520)
            if let blockedHost {
                notice("Blocked a page from “\(blockedHost)”. VGN only loads GOG's login pages.",
                       systemImage: "hand.raised.fill")
            }
            if let failure {
                notice("Sign-in failed: \(failure)", systemImage: "exclamationmark.triangle.fill")
            }
        }
        .frame(width: 560, height: 640)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isLoading ? "lock" : "lock.fill").foregroundStyle(.secondary)
            // Read-only address line (anti-phishing): the host only, never the query.
            Text(currentHost.isEmpty ? "auth.gog.com" : currentHost)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.4))
    }
}

/// The thin WebKit shell: a non-persistent `WKWebView` that routes every navigation
/// through ``GOGLoginNavigationPolicy``.
private struct GOGLoginWebView: NSViewRepresentable {
    let url: URL
    let policy: GOGLoginNavigationPolicy
    let onHostChange: (String) -> Void
    let onLoadingChange: (Bool) -> Void
    let onBlocked: (String) -> Void
    let onCompleted: (String) -> Void
    let onFailed: (String) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Non-persistent: cookies / storage live only for this sheet (PLAN §14.1).
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: GOGLoginWebView
        private var finished = false

        init(_ parent: GOGLoginWebView) { self.parent = parent }

        @MainActor
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            switch parent.policy.decide(url: url) {
            case .allow:
                parent.onHostChange(url.host ?? "")
                return .allow
            case .block(let host):
                parent.onBlocked(host)
                return .cancel
            case .completed(let code):
                finishOnce { parent.onCompleted(code) }   // code never logged
                return .cancel
            case .failed(let reason):
                finishOnce { parent.onFailed(reason) }
                return .cancel
            case .cancelled:
                finishOnce { parent.onCancelled() }
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChange(true)
            if let host = webView.url?.host { parent.onHostChange(host) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChange(false)
        }

        /// Fire a terminal outcome exactly once (redirects can arrive twice).
        private func finishOnce(_ action: () -> Void) {
            guard !finished else { return }
            finished = true
            action()
        }
    }
}
