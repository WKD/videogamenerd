import SwiftUI
import WebKit

/// Pure NPSSO-cookie matching for the PSN login sheet (PLAN §13.1). Kept out of the
/// WebKit shell so it is unit-tested with constructed cookies and never needs a browser.
/// The returned value is the NPSSO itself — the caller passes it straight to
/// ``PSNAuth/completeSignIn(npsso:)`` and it is **never** logged, labelled or shown.
enum PSNLoginCookies {
    /// The value of the `name` cookie set on `domain` (exact host or a subdomain), or nil.
    /// A cookie with an empty value is treated as absent (Sony clears it before setting it).
    static func npssoValue(from cookies: [(name: String, domain: String, value: String)],
                           name: String, domain: String) -> String? {
        let wantedName = name.lowercased()
        let wantedDomain = domain.lowercased()
        for cookie in cookies where cookie.name.lowercased() == wantedName {
            let host = cookie.domain.lowercased().drop(while: { $0 == "." })
            let h = String(host)
            if h == wantedDomain || h.hasSuffix("." + wantedDomain) || wantedDomain.hasSuffix("." + h) {
                let value = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Adapter for real `HTTPCookie`s.
    static func npssoValue(from cookies: [HTTPCookie], name: String, domain: String) -> String? {
        npssoValue(from: cookies.map { ($0.name, $0.domain, $0.value) }, name: name, domain: domain)
    }
}

// MARK: - Login sheet

/// Sony's login page in a **non-persistent** `WKWebView` (PLAN §13.1): VGN never sees the
/// password. A `WKNavigationDelegate` cancels off-allow-list main-frame navigation (using
/// the pure ``PSNLoginNavigationPolicy``; sub-frames are allowed — Sony's login uses a
/// captcha iframe) and, after each page load, reads the **npsso** cookie from the web
/// view's own cookie store. Once present it is handed to ``completeSignIn`` and the sheet
/// closes. The current host is shown read-only (anti-phishing); the NPSSO never reaches
/// the UI. If the cookie is not found within a bounded wait, a message points at the
/// "Paste NPSSO instead" fallback.
///
/// `import WebKit` is confined to this one file.
struct PSNLoginSheet: View {
    let config: PSNLoginConfig
    /// Called with the NPSSO read from the cookie store (never logged). The account model
    /// exchanges it for tokens and dismisses.
    let completeSignIn: (String) -> Void
    let onCancel: () -> Void
    let onFailed: (String) -> Void

    @State private var currentHost = ""
    @State private var isLoading = true
    @State private var blockedHost: String?
    @State private var timedOut = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            PSNLoginWebView(
                config: config,
                onHostChange: { currentHost = $0 },
                onLoadingChange: { isLoading = $0 },
                onBlocked: { blockedHost = $0 },
                onCompleted: { npsso in completeSignIn(npsso) })
            .frame(minWidth: 520, minHeight: 520)
            if let blockedHost {
                notice("Blocked a page from “\(blockedHost)”. VGN only loads Sony's sign-in pages.",
                       systemImage: "hand.raised.fill")
            }
            if timedOut {
                notice("Still can't read the sign-in token. Close this and use “Paste NPSSO instead”.",
                       systemImage: "questionmark.circle.fill")
            }
        }
        .frame(width: 560, height: 660)
        .task {
            // Bounded wait: after a couple of minutes with no npsso cookie, point at the
            // paste fallback rather than spin forever.
            try? await Task.sleep(for: .seconds(120))
            timedOut = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isLoading ? "lock" : "lock.fill").foregroundStyle(.secondary)
            // Read-only address line (anti-phishing): the host only, never the query.
            Text(currentHost.isEmpty ? config.loginURL.host ?? "playstation.com" : currentHost)
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

/// The thin WebKit shell: a non-persistent `WKWebView` that gates main-frame navigation
/// through the pure ``PSNLoginNavigationPolicy`` and reads the npsso cookie after each load.
private struct PSNLoginWebView: NSViewRepresentable {
    let config: PSNLoginConfig
    let onHostChange: (String) -> Void
    let onLoadingChange: (Bool) -> Void
    let onBlocked: (String) -> Void
    let onCompleted: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent: cookies / storage live only for this sheet (PLAN §13.1).
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: config.loginURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: PSNLoginWebView
        private var finished = false

        init(_ parent: PSNLoginWebView) { self.parent = parent }

        @MainActor
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            switch parent.config.policy.decision(for: url, isMainFrame: isMainFrame) {
            case .allow:
                if isMainFrame, let host = url.host { parent.onHostChange(host) }
                return .allow
            case .block:
                if isMainFrame { parent.onBlocked(url.host ?? url.absoluteString) }
                return isMainFrame ? .cancel : .allow
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChange(true)
            if let host = webView.url?.host { parent.onHostChange(host) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChange(false)
            readNPSSO(from: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChange(false)
        }

        /// Read the npsso cookie from the web view's own cookie store; fire once when found.
        @MainActor
        private func readNPSSO(from webView: WKWebView) {
            guard !finished else { return }
            let name = parent.config.npssoCookieName
            let domain = parent.config.npssoCookieDomain
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.finished else { return }
                if let npsso = PSNLoginCookies.npssoValue(from: cookies, name: name, domain: domain) {
                    self.finished = true
                    self.parent.onCompleted(npsso)   // NPSSO never logged
                }
            }
        }
    }
}
