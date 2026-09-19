import Foundation
import Testing
@testable import VGN

/// The PSN client actor (PLAN §13.1/§13.5): allow-list, budget, pacer, retry table,
/// the probe-before-full guard, and cache-first reads. All offline.
@Suite struct PSNClientTests {

    private func makeCache() async throws -> ImportResponseCacheStore {
        ImportResponseCacheStore(try await ImportTestDB.makeSeeded())
    }
    private func noPacing(budget: Int = 40) -> ImportPolicy.Pacing {
        ImportPolicy.Pacing(minDelay: 0, jitter: 0, budget: budget)
    }

    // MARK: - Allow-list

    @Test func allowListAcceptsOnlyReadEndpoints() {
        let a = ImportAllowList.psn
        #expect(a.allows(URL(string: "https://m.np.playstation.com/api/trophy/v1/users/me/trophyTitles?npServiceName=trophy2")!))
        #expect(a.allows(URL(string: "https://web.np.playstation.com/api/graphql/v1/op?operationName=getPurchasedGameList")!))
        #expect(!a.allows(URL(string: "https://m.np.playstation.com/api/trophy/v1/users/me/trophyGroups")!))
        #expect(!a.allows(URL(string: "https://evil.example/")!))
    }

    // MARK: - Budget

    @Test func budgetAbortsTheSync() async throws {
        let cache = try await makeCache()
        let transport = try psnHappyPathTransport()
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(budget: 1),
                               clock: RecordingImmediateClock(), wallClock: { importFixedNow })
        _ = try await client.profile()              // 1st request — ok
        await #expect(throws: ImportError.self) {    // 2nd — budget exhausted
            _ = try await client.probe(.gameList)
        }
    }

    // MARK: - Probe-before-full guard

    @Test func fullFetchRefusesWithoutAProbe() async throws {
        let cache = try await makeCache()
        let transport = try psnHappyPathTransport()
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(),
                               clock: RecordingImmediateClock(), wallClock: { importFixedNow })
        // No probe yet → a full page refuses.
        do {
            _ = try await client.trophyTitlesPage(service: "trophy2", limit: 800, offset: 0)
            Issue.record("expected probeRequired")
        } catch let error as PSNClient.ClientError {
            #expect(error == .probeRequired("probe:trophyTitles:trophy2:real"))
        }
        // After a probe, the full page proceeds.
        _ = try await client.probe(.trophyTitles(service: "trophy2"))
        #expect(try await client.hasProbe(for: .trophyTitles(service: "trophy2")))
        _ = try await client.trophyTitlesPage(service: "trophy2", limit: 800, offset: 0)
    }

    // MARK: - Retry table

    @Test func rateLimitEndsTheSync() async throws {
        let cache = try await makeCache()
        let transport = StubHTTPTransport(defaultStub: .init(status: 429,
            body: Data("{}".utf8), headers: ["Retry-After": "5", "Content-Type": "application/json"]))
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(),
                               clock: RecordingImmediateClock(), wallClock: { importFixedNow })
        await #expect(throws: ImportError.self) {
            _ = try await client.gameListPage(limit: 10, offset: 0, requireProbe: false)
        }
        #expect(await client.reachedRateLimitEnd)
        #expect(transport.requestCount == 2)   // one retry after Retry-After, then stop
    }

    @Test func forbiddenStops() async throws {
        let cache = try await makeCache()
        let transport = StubHTTPTransport(defaultStub: .init(status: 403,
            body: Data("{}".utf8), headers: ["Content-Type": "application/json"]))
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(),
                               clock: RecordingImmediateClock(), wallClock: { importFixedNow })
        do {
            _ = try await client.gameListPage(limit: 10, offset: 0, requireProbe: false)
            Issue.record("expected reject")
        } catch let ImportError.rejected(reject) {
            #expect(reject.reason == .authChallenge)
        }
        #expect(transport.requestCount == 1)
    }

    @Test func unauthorizedRefreshesTokenOnceThenProceeds() async throws {
        let cache = try await makeCache()
        let transport = First401Transport(
            profileBody: try Fixtures.data("psn-profile.json"),
            tokenBody: try Fixtures.data("psn-token.json"))
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(),
                               clock: RecordingImmediateClock(), wallClock: { importFixedNow })
        let profile = try await client.profile()
        #expect(profile.onlineId != nil)
        #expect(transport.profileCalls == 2)   // 401, refresh, then 200
        #expect(transport.tokenCalls == 1)
    }

    // MARK: - Cache-first

    @Test func secondReadIsServedFromCacheWithoutANetworkCall() async throws {
        let cache = try await makeCache()
        let transport = try psnHappyPathTransport()
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: noPacing(), clock: RecordingImmediateClock(),
                               wallClock: { importFixedNow })
        _ = try await client.profile()
        _ = try await client.profile()
        #expect(await client.fromNetwork == 1)
        #expect(await client.fromCache == 1)
        let profileRequests = transport.requests.filter { ($0.url?.absoluteString ?? "").contains("me/profile2") }
        #expect(profileRequests.count == 1)
        // Every PSN request carries the reference client's headers — the GraphQL gateway
        // rejects a GET without a JSON content type as a potential CSRF (live, 2026-09-19).
        for request in transport.requests {
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        }
    }

    // MARK: - Pacer

    @Test func requestsArePaced() async throws {
        let cache = try await makeCache()
        let transport = try psnHappyPathTransport()
        let clock = RecordingImmediateClock()
        let client = PSNClient(transport: transport, auth: seededPSNAuth(transport: transport),
                               cache: cache, pacing: ImportPolicy.psn, clock: clock,
                               wallClock: { importFixedNow })
        _ = try await client.profile()
        _ = try await client.probe(.gameList)
        // Two network requests → at least one inter-request wait was scheduled.
        #expect(clock.deadlines.count >= 1)
    }
}

/// A transport that answers the profile URL 401 the first time then 200, and always 200
/// for the token endpoint — drives the single-401-refresh retry path.
final class First401Transport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var profileCalls = 0
    private(set) var tokenCalls = 0
    let profileBody: Data
    let tokenBody: Data

    init(profileBody: Data, tokenBody: Data) {
        self.profileBody = profileBody
        self.tokenBody = tokenBody
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url?.absoluteString ?? ""
        func resp(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"])!
        }
        if url.contains("oauth/token") {
            lock.withLock { tokenCalls += 1 }
            return (tokenBody, resp(200))
        }
        if url.contains("me/profile2") {
            let first = lock.withLock { () -> Bool in profileCalls += 1; return profileCalls == 1 }
            return (profileBody, resp(first ? 401 : 200))
        }
        return (Data("{}".utf8), resp(200))
    }
}
