import Foundation
import Testing
@testable import VGN

/// Live finding 2026-09-20: after signing out of the test account and into the real one, the
/// endpoint-only cache key served the real account the TEST account's cached profile and
/// empty lists ("from cache · 0 requests"). Every cache key and probe marker now belongs
/// to one login session.
@Suite(.serialized)
struct PSNCacheScopeTests {
    private func client(_ transport: StubHTTPTransport, cache: ImportResponseCacheStore, auth: PSNAuth) -> PSNClient {
        PSNClient(transport: transport, auth: auth, cache: cache, pacing: ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: 40),
                  clock: RecordingImmediateClock(), wallClock: { importFixedNow })
    }

    private func requests(_ transport: StubHTTPTransport, containing text: String) -> Int {
        transport.requests.filter { ($0.url?.absoluteString ?? "").contains(text) }.count
    }

    @Test(.timeLimit(.minutes(1)))
    func aSecondSignInNeverSeesTheFirstAccountsCache() async throws {
        let db = try AppDatabase.inMemory()
        let cache = ImportResponseCacheStore(db)
        let transport = try psnHappyPathTransport()

        // Account A: probe + profile, then the same again → served from cache.
        let authA = seededPSNAuth(transport: transport, scope: "session-A")
        let a = client(transport, cache: cache, auth: authA)
        _ = try await a.profile()
        _ = try await a.probe(.gameList)
        _ = try await a.profile()
        #expect(requests(transport, containing: "me/profile2") == 1)
        #expect(try await a.hasProbe(for: .gameList))

        // Account B signs in on the same machine, same database, same cache table.
        let authB = seededPSNAuth(transport: transport, scope: "session-B")
        #expect(try await authA.cacheScope() != authB.cacheScope())
        let b = client(transport, cache: cache, auth: authB)
        #expect(try await b.hasProbe(for: .gameList) == false, "B must probe for itself")
        _ = try await b.profile()
        #expect(requests(transport, containing: "me/profile2") == 2, "B's profile must come from the network, not A's cache")
        await #expect(throws: (any Error).self) { _ = try await b.gameListPage(limit: 200, offset: 0) }
    }

    @Test(.timeLimit(.minutes(1)))
    func theScopeSurvivesATokenRefreshAndOldStoredTokensGetOne() async throws {
        let transport = try psnHappyPathTransport()
        let auth = seededPSNAuth(transport: transport)
        let before = try await auth.cacheScope()
        _ = try await auth.forceRefresh()
        #expect(try await auth.cacheScope() == before)

        // A token stored before scopes existed decodes with a fresh, non-empty scope.
        let legacy = #"{"accessToken":"a","refreshToken":"r","expiresAt":0,"refreshExpiresAt":0}"#
        let decoded = try JSONDecoder().decode(PSNStoredToken.self, from: Data(legacy.utf8))
        #expect(!decoded.cacheScope.isEmpty)
    }
}
