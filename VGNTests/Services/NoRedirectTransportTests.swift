import Foundation
import Testing
@testable import VGN

/// The PSN `authorize` step answers with a 302 to a custom-scheme URL carrying the code.
/// A redirect-following session fails with "unsupported URL" (first live sign-in,
/// 2026-09-19); the no-redirect transport must hand the 302 back so the code can be read.
@Suite(.serialized)
struct NoRedirectTransportTests {
    final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
        static let location = "com.scee.psxandroid.scecompcall://redirect/?code=v3.TESTCODE&cid=abc"
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "auth.example.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.location])!
            var next = URLRequest(url: URL(string: Self.location)!)
            next.httpMethod = "GET"
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // When the session refuses the redirect, the 302 itself is the final response.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @Test(.timeLimit(.minutes(1)))
    func theRedirectResponseIsReturnedNotFollowed() async throws {
        let transport = URLSessionTransport.ephemeral(followRedirects: false, timeout: 5,
                                                      protocolClasses: [RedirectingProtocol.self])
        let (_, response) = try await transport.data(for: URLRequest(url: URL(string: "https://auth.example.test/authorize")!))
        #expect(response.statusCode == 302)
        #expect(response.value(forHTTPHeaderField: "Location") == RedirectingProtocol.location)
        #expect(PSNAuth.authorizationCode(from: response, redirectURI: "com.scee.psxandroid.scecompcall://redirect") == "v3.TESTCODE")
    }

    @Test(.timeLimit(.minutes(1)))
    func aRedirectFollowingSessionCannotReadIt() async throws {
        let transport = URLSessionTransport.ephemeral(followRedirects: true, timeout: 5,
                                                      protocolClasses: [RedirectingProtocol.self])
        await #expect(throws: (any Error).self) {
            _ = try await transport.data(for: URLRequest(url: URL(string: "https://auth.example.test/authorize")!))
        }
    }
}
