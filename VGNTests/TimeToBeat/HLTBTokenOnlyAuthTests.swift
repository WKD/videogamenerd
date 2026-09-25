import Foundation
import Testing
import GRDB
@testable import VGN

/// Wave 21 E — HowLongToBeat's `/init` answers `{ "token": … }` only since 2026-09-24.
/// A token-only session is accepted (no `x-hp-*` header, no body field); a reply without a
/// string token is still a schemaMismatch reject on `hltb/auth`. All offline.
@Suite struct HLTBTokenOnlyAuthTests {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - parseAuth

    @Test func tokenOnlyInitIsAccepted() {
        let auth = HLTBEndpoint.parseAuth(json(#"{"token":"abc123"}"#))
        #expect(auth?.token == "abc123")
        #expect(auth?.key == nil && auth?.value == nil)
        #expect(auth?.hpPair == nil)
    }

    @Test func legacyTokenKeyValShapeStillParses() throws {
        let auth = HLTBEndpoint.parseAuth(try Fixtures.data("hltb-init.json"))
        #expect(auth?.hpPair?.key == "ign_test1234")
        #expect(auth?.hpPair?.value == "deadbeefcafe0001")
    }

    @Test func missingOrNonStringTokenIsRejected() {
        #expect(HLTBEndpoint.parseAuth(json(#"{"hpKey":"k","hpVal":"v"}"#)) == nil)   // no token
        #expect(HLTBEndpoint.parseAuth(json(#"{"token":12345}"#)) == nil)              // not a string
        #expect(HLTBEndpoint.parseAuth(json(#"{"token":null}"#)) == nil)
        #expect(HLTBEndpoint.parseAuth(json(#"{"token":""}"#)) == nil)                 // empty
        #expect(HLTBEndpoint.parseAuth(json(#"["token"]"#)) == nil)                    // not an object
        #expect(HLTBEndpoint.parseAuth(json(#"{"token":"t","hpKey":"k"}"#)) == nil)    // half a pair
    }

    // MARK: - Request shape

    @Test func tokenOnlySearchSendsOnlyTheAuthTokenHeader() {
        let req = HLTBEndpoint.searchRequest(title: "X", discovery: .fallback, auth: .init(token: "TKN"))
        #expect(req.value(forHTTPHeaderField: "x-auth-token") == "TKN")
        #expect(req.value(forHTTPHeaderField: "x-hp-key") == nil)
        #expect(req.value(forHTTPHeaderField: "x-hp-val") == nil)
        // The body carries no dynamic field: same keys as an unauthenticated payload.
        let withToken = try! JSONSerialization.jsonObject(
            with: HLTBEndpoint.searchPayload(title: "X", auth: .init(token: "TKN"))) as! [String: Any]
        let plain = try! JSONSerialization.jsonObject(
            with: HLTBEndpoint.searchPayload(title: "X", auth: nil)) as! [String: Any]
        #expect(Set(withToken.keys) == Set(plain.keys))
    }

    @Test func fullPairStillSendsHeadersAndBodyField() {
        let auth = HLTBEndpoint.Auth(token: "TKN", key: "ign_abc", value: "xyz")
        let req = HLTBEndpoint.searchRequest(title: "X", discovery: .fallback, auth: auth)
        #expect(req.value(forHTTPHeaderField: "x-hp-key") == "ign_abc")
        #expect(req.value(forHTTPHeaderField: "x-hp-val") == "xyz")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        #expect(body["ign_abc"] as? String == "xyz")
    }

    // MARK: - Client

    private func transport(initBody: String, searchFixture: String = "hltb-search-bloodborne.json") throws -> StubHTTPTransport {
        let t = StubHTTPTransport(defaultStub: .init(
            status: 200, body: try Fixtures.data("hltb-discovery-home.html"), headers: ["Content-Type": "text/html"]))
        t.on(urlContains: "/_next/", .init(status: 200, body: try Fixtures.data("hltb-discovery-app.js"),
                                           headers: ["Content-Type": "application/javascript"]))
        t.on(urlContains: "/init", .init(status: 200, body: Data(initBody.utf8),
                                         headers: ["Content-Type": "application/json"]))
        t.on(urlContains: "/api/", .init(status: 200, body: try Fixtures.data(searchFixture),
                                         headers: ["Content-Type": "application/json"]))
        return t
    }

    @Test func clientSearchesWithATokenOnlySession() async throws {
        let t = try transport(initBody: #"{"token":"VEVTVF9UT0tFTl9PTkxZ"}"#)
        let cache = ImportResponseCacheStore(try AppDatabase.inMemory())
        let client = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock())
        let results = try await client.search(title: "Bloodborne")
        #expect(results.first?.id == 21262)
        #expect(t.requestCount == 4)   // homepage + chunk + /init + search
        let search = try #require(t.requests.last)
        #expect(search.value(forHTTPHeaderField: "x-auth-token") == "VEVTVF9UT0tFTl9PTkxZ")
        #expect(search.value(forHTTPHeaderField: "x-hp-key") == nil)
        #expect(search.value(forHTTPHeaderField: "x-hp-val") == nil)
        #expect(try await cache.rejectCount(source: HLTBSource.id) == 0)
    }

    @Test func clientRejectsInitWithoutAStringToken() async throws {
        let t = try transport(initBody: #"{"token":42}"#)
        let cache = ImportResponseCacheStore(try AppDatabase.inMemory())
        let client = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock())
        do {
            _ = try await client.search(title: "Bloodborne")
            Issue.record("expected a reject")
        } catch ImportError.rejected(let reject) {
            #expect(reject.endpoint == HLTBClient.authEndpoint)
            #expect(reject.reason == .schemaMismatch)
        }
        #expect(t.requestCount == 3)   // never reached the search
        #expect(try await cache.rejectCount(source: HLTBSource.id) == 1)
    }

    /// The owner's reject: an `/init` excerpt carrying a token that embeds an IP + UA must be
    /// stored redacted, shape kept.
    @Test func rejectExcerptNeverStoresTheTokensIPOrUA() async throws {
        let token = RedactionSamples.ownerShapedToken
        // An unexpected /init shape that still carries the token (half a pair) → reject.
        let t = try transport(initBody: #"{"token":"\#(token)","hpKey":"k"}"#)
        let cache = ImportResponseCacheStore(try AppDatabase.inMemory())
        let client = HLTBClient(transport: t, cache: cache, clock: RecordingImmediateClock())
        await #expect(throws: ImportError.self) { try await client.search(title: "Bloodborne") }
        let excerpt = try await cache.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT body_excerpt FROM import_cache_rejects WHERE source = 'hltb'")
        }
        let stored = try #require(excerpt)
        #expect(!stored.contains(token))
        #expect(!stored.contains("203.0.113.7"))
        #expect(stored.contains(#""token":"‹redacted›""#))
        #expect(stored.contains(#""hpKey":"k""#))   // shape still explains the mismatch
    }
}

/// Synthetic credential shapes for the redaction tests — never real values.
enum RedactionSamples {
    /// `<ms>::<IP>|<User-Agent>.<hex>` in base64 — the shape HowLongToBeat's token has, with
    /// the documentation IP 203.0.113.7.
    static let ownerShapedToken: String = Data(
        ("1727218680000::203.0.113.7|Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
         + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36.0a1b2c3d4e5f").utf8
    ).base64EncodedString()
}

/// Wave 21 E — ``ImportRedactor/redactSecretValues(_:)``: credential values go, key names
/// and shape stay.
@Suite struct ImportRedactorSecretValueTests {

    private let p = ImportRedactor.placeholder

    @Test func ownerShapedInitExcerptIsRedactedShapeKept() {
        let token = RedactionSamples.ownerShapedToken
        let out = ImportRedactor.redactSecretValues(#"{"token":"\#(token)"}"#)
        #expect(out == #"{"token":"\#(p)"}"#)
        // Also through the full redactor (what the reject log uses).
        #expect(ImportRedactor.structural.redact(#"{"token":"\#(token)"}"#) == #"{"token":"\#(p)"}"#)
    }

    @Test func namedSecretKeysLoseTheirValuesOnly() {
        let input = #"{"access_token":"a1","refresh_token":"r2","npsso":"n3","Authorization":"Bearer z","hpVal":"v4","hpKey":"ign_k","id":7}"#
        let out = ImportRedactor.redactSecretValues(input)
        #expect(out == #"{"access_token":"\#(p)","refresh_token":"\#(p)","npsso":"\#(p)","Authorization":"\#(p)","hpVal":"\#(p)","hpKey":"ign_k","id":7}"#)
    }

    @Test func base64CarryingAnIPUnderAnyKeyIsRedacted() {
        let v4 = Data("something 203.0.113.7 here".utf8).base64EncodedString()
        let v6 = Data("x::y 2001:db8::7 z".utf8).base64EncodedString()
        let ua = Data("abc|Mozilla/5.0".utf8).base64EncodedString()
        let out = ImportRedactor.redactSecretValues(#"{"a":"\#(v4)","b":"\#(v6)","c":"\#(ua)"}"#)
        #expect(out == #"{"a":"\#(p)","b":"\#(p)","c":"\#(p)"}"#)
    }

    @Test func plainIPAddressesAreRedacted() {
        let out = ImportRedactor.redactSecretValues(#"{"ip":"203.0.113.7","v6":"2001:db8:0:0:0:0:0:7"}"#)
        #expect(!out.contains("203.0.113.7") && !out.contains("2001:db8"))
        #expect(out.contains(#""ip":"#) && out.contains(#""v6":"#))
    }

    @Test func harmlessContentIsLeftAlone() {
        let input = #"{"error":"bad request","count":3,"data":[{"game_name":"Bloodborne","game_id":21262}],"note":"SGVsbG8gV29ybGQgbm90aGluZyBoZXJl"}"#
        #expect(ImportRedactor.redactSecretValues(input) == input)
    }

    @Test func truncatedExcerptIsStillRedacted() {
        let out = ImportRedactor.redactSecretValues(#"{"x":1,"token":"VEVTVF9UT0tF"#)
        #expect(out == #"{"x":1,"token":"\#(p)""#)
    }

    @Test func oauthCodeStringAndQueryCredentialsAreRedactedErrorCodesKept() {
        #expect(ImportRedactor.redactSecretValues(#"{"code":"oauth-xyz","error":{"code":403}}"#)
            == #"{"code":"\#(p)","error":{"code":403}}"#)
        #expect(ImportRedactor.redactSecretValues("https://x.test/cb?code=abc123&state=s")
            == "https://x.test/cb?code=\(p)&state=s")
    }

    @Test func authorizationHeaderLineIsRedacted() {
        let out = ImportRedactor.redactSecretValues("GET /x\nAuthorization: Bearer abc.def\nAccept: */*")
        #expect(out == "GET /x\nAuthorization: \(p)\nAccept: */*")
    }
}

/// Wave 21 E — the owner's explicit "Clear rejected-response log (N)" store action.
@Suite struct ImportRejectLogClearTests {

    @Test func clearRejectsRemovesOnlyThatSourcesRowsInOneGo() async throws {
        let store = ImportResponseCacheStore(try AppDatabase.inMemory())
        for i in 0..<3 {
            try await store.recordReject(ImportReject(
                source: HLTBSource.id, endpoint: HLTBClient.authEndpoint, status: 200,
                reason: .schemaMismatch, redactedExcerpt: "x\(i)", receivedAt: importFixedNow))
        }
        try await store.recordReject(ImportReject(
            source: ImportSourceID.gog, endpoint: "e", reason: .unknown, redactedExcerpt: "g",
            receivedAt: importFixedNow))
        try await store.store(ImportCacheRecord(
            source: HLTBSource.id, key: "search:x", endpoint: HLTBClient.searchEndpoint, paramsJSON: "{}",
            fetchedAt: importFixedNow, expiresAt: importFixedNow.addingTimeInterval(86_400),
            status: 200, body: Data(#"{"data":[]}"#.utf8), itemCount: 0, schemaVersion: 1))

        #expect(try await store.clearRejects(source: HLTBSource.id) == 3)
        #expect(try await store.rejectCount(source: HLTBSource.id) == 0)
        #expect(try await store.rejectCount(source: ImportSourceID.gog) == 1)   // other source kept
        #expect(try await store.entry(source: HLTBSource.id, key: "search:x") != nil)   // cache kept
        #expect(try await store.clearRejects(source: HLTBSource.id) == 0)
    }
}
