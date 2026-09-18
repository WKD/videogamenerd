import Foundation
import Testing
@testable import VGN

/// Mutable, thread-safe clock source for the token provider's `now`.
private final class MutableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    var callable: @Sendable () -> Date { { self.lock.withLock { self.date } } }
}

private func tokenStub(_ token: String, expiresIn: Int = 3600) -> StubHTTPTransport.Stub {
    let json = #"{"access_token":"\#(token)","expires_in":\#(expiresIn),"token_type":"bearer"}"#
    return .init(status: 200, body: Data(json.utf8))
}

private let creds: @Sendable () async -> IGDBCredentials? = {
    IGDBCredentials(clientID: "test-client", secret: "test-secret")
}

private func twitchRequestCount(_ transport: StubHTTPTransport) -> Int {
    transport.requests.filter { ($0.url?.absoluteString.contains("id.twitch.tv") ?? false) }.count
}

struct IGDBTokenProviderTests {

    @Test("Caches the token across calls (one network fetch)")
    func caches() async throws {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv", tokenStub("tok"))
        let provider = IGDBTokenProvider(transport: transport, credentials: creds)

        let a = try await provider.validToken()
        let b = try await provider.validToken()
        #expect(a == "tok")
        #expect(b == "tok")
        #expect(twitchRequestCount(transport) == 1)
    }

    @Test("Concurrent callers share a single in-flight refresh")
    func singleFlight() async throws {
        let transport = StubHTTPTransport(perRequestDelay: 0.05)
        transport.on(urlContains: "id.twitch.tv", tokenStub("tok"))
        let provider = IGDBTokenProvider(transport: transport, credentials: creds)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<8 { group.addTask { try await provider.validToken() } }
            var out: [String] = []
            for try await value in group { out.append(value) }
            return out
        }
        #expect(tokens.allSatisfy { $0 == "tok" })
        #expect(twitchRequestCount(transport) == 1)
    }

    @Test("Refetches once the token nears expiry")
    func expiry() async throws {
        let now = MutableNow(Date(timeIntervalSince1970: 0))
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv", tokenStub("tok", expiresIn: 3600))
        let provider = IGDBTokenProvider(transport: transport, credentials: creds, now: now.callable)

        _ = try await provider.validToken()
        #expect(twitchRequestCount(transport) == 1)

        // Still fresh 30 min in — no refetch.
        now.advance(1800)
        _ = try await provider.validToken()
        #expect(twitchRequestCount(transport) == 1)

        // Past expiry (minus leeway) — refetch.
        now.advance(3600)
        _ = try await provider.validToken()
        #expect(twitchRequestCount(transport) == 2)
    }

    @Test("forceRefresh always fetches a fresh token (the 401 path)")
    func forceRefresh() async throws {
        let transport = StubHTTPTransport()
        transport.on(urlContains: "id.twitch.tv", tokenStub("tok"))
        let provider = IGDBTokenProvider(transport: transport, credentials: creds)

        _ = try await provider.validToken()
        _ = try await provider.forceRefresh()
        #expect(twitchRequestCount(transport) == 2)
    }

    @Test("Missing credentials surface as .missingCredentials")
    func missingCredentials() async {
        let transport = StubHTTPTransport()
        let provider = IGDBTokenProvider(transport: transport, credentials: { nil })
        await #expect(throws: IGDBError.missingCredentials) {
            _ = try await provider.validToken()
        }
    }
}
