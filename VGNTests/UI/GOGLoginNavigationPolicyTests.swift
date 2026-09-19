import Foundation
import Testing
@testable import VGN

/// The pure GOG login navigation policy (PLAN §14.1): allowed hosts, blocked hosts, the
/// success redirect carrying the code, error/cancel redirects, and the guarantee that the
/// code never appears in any log/description string.
struct GOGLoginNavigationPolicyTests {
    private func policy() -> GOGLoginNavigationPolicy {
        GOGLoginNavigationPolicy(
            parser: GOGAuthRedirectParser(redirectURI: "https://embed.gog.com/on_login_success?origin=client"),
            allowedHosts: ["auth.gog.com", "login.gog.com", "www.gog.com", "gog.com"])
    }

    @Test func allowsLoginHosts() {
        #expect(policy().decide(url: URL(string: "https://auth.gog.com/auth?client_id=x")!) == .allow)
        #expect(policy().decide(url: URL(string: "https://login.gog.com/login_check")!) == .allow)
        // A subdomain of a listed bare domain is allowed too.
        #expect(policy().decide(url: URL(string: "https://images.gog.com/logo.png")!) == .allow)
    }

    @Test func blocksForeignHost() {
        #expect(policy().decide(url: URL(string: "https://evil.example.com/phish")!) == .block(host: "evil.example.com"))
    }

    @Test func successRedirectYieldsCode() {
        let url = URL(string: "https://embed.gog.com/on_login_success?code=ABC123XYZ&origin=client")!
        #expect(policy().decide(url: url) == .completed(code: "ABC123XYZ"))
    }

    @Test func accessDeniedIsCancelled() {
        let url = URL(string: "https://embed.gog.com/on_login_success?error=access_denied")!
        #expect(policy().decide(url: url) == .cancelled)
    }

    @Test func errorRedirectFails() {
        let url = URL(string: "https://embed.gog.com/on_login_success?error=server_error&error_description=Boom")!
        #expect(policy().decide(url: url) == .failed(reason: "Boom"))
    }

    /// The success redirect host (`embed.gog.com`) is NOT on the browse allow-list, so it
    /// must be parsed before the host check — else the code would be blocked.
    @Test func redirectIsParsedBeforeHostCheck() {
        let url = URL(string: "https://embed.gog.com/on_login_success?code=Q")!
        // With a policy that does NOT list embed.gog.com, the code is still extracted.
        let strict = GOGLoginNavigationPolicy(
            parser: GOGAuthRedirectParser(redirectURI: "https://embed.gog.com/on_login_success"),
            allowedHosts: ["auth.gog.com"])
        #expect(strict.decide(url: url) == .completed(code: "Q"))
    }

    @Test func codeNeverAppearsInLogDescription() {
        let decision = GOGLoginNavigationPolicy.Decision.completed(code: "SUPER-SECRET-CODE")
        #expect(decision.logDescription == "completed")
        #expect(!decision.logDescription.contains("SUPER-SECRET-CODE"))
    }

    @Test func hostMatchIsExactOrSubdomain() {
        #expect(GOGLoginNavigationPolicy.isAllowed(host: "auth.gog.com", in: ["gog.com"]))
        #expect(GOGLoginNavigationPolicy.isAllowed(host: "gog.com", in: ["gog.com"]))
        #expect(!GOGLoginNavigationPolicy.isAllowed(host: "notgog.com", in: ["gog.com"]))
        #expect(!GOGLoginNavigationPolicy.isAllowed(host: "gog.com.evil.com", in: ["gog.com"]))
    }
}
