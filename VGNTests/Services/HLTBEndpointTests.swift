import Foundation
import Testing
@testable import VGN

/// The isolated HLTB request/response mechanics (PLAN §5.3): endpoint discovery,
/// per-session auth parsing, the search payload, and DTO decoding — all pure, driven by
/// fixtures recorded / shaped from the live site (verified 2026-09-19).
@Suite struct HLTBEndpointTests {

    // MARK: - Discovery

    @Test func scriptPathsExtractedInDocumentOrder() throws {
        let html = try String(decoding: Fixtures.data("hltb-discovery-home.html"), as: UTF8.self)
        let paths = HLTBEndpoint.scriptPaths(inHTML: html)
        #expect(paths.count == 2)
        #expect(paths.allSatisfy { $0.hasPrefix("/_next/static/chunks/") })
        // Turbopack names are opaque hashes — no _app/main to prioritise; order kept.
        #expect(paths.first == "/_next/static/chunks/1ygls5xciw8_y.js")
    }

    @Test func discoveryResolvesPostFetchEndpoint() throws {
        let js = try String(decoding: Fixtures.data("hltb-discovery-app.js"), as: UTF8.self)
        let d = HLTBEndpoint.resolveDiscovery(fromScript: js)
        // The POST fetch marks the real search endpoint; the init GET is ignored.
        #expect(d?.searchPath == "api/search/site")
        #expect(d?.searchURL.absoluteString == "https://howlongtobeat.com/api/search/site")
        #expect(d?.initPath == "api/search/site/init")
    }

    @Test func discoveryTakesTheWholeSlashedPath() {
        let js = #"x=fetch("/api/finder/v2",{method:"POST",body:b});"#
        #expect(HLTBEndpoint.resolveDiscovery(fromScript: js)?.searchPath == "api/finder/v2")
    }

    @Test func discoveryStripsTrailingSlashOnBareEndpoint() {
        let js = #"var f=function(a){return fetch("/api/s/",{method:"POST",body:a})};"#
        #expect(HLTBEndpoint.resolveDiscovery(fromScript: js)?.searchPath == "api/s")
    }

    @Test func discoveryIgnoresApiGetsWithoutPost() {
        // A GET to /api/... (no method:"POST") is not the search endpoint.
        let js = #"fetch("/api/user/profile",{headers:{a:1}}); fetch(`/api/ping?t=${x}`);"#
        #expect(HLTBEndpoint.resolveDiscovery(fromScript: js) == nil)
    }

    @Test func discoveryFailsGracefullyOnUnrelatedScript() {
        #expect(HLTBEndpoint.resolveDiscovery(fromScript: "console.log('no endpoint here');") == nil)
    }

    // MARK: - Auth

    @Test func parseAuthReadsTokenAndKeyValDefensively() throws {
        let auth = HLTBEndpoint.parseAuth(try Fixtures.data("hltb-init.json"))
        #expect(auth?.token == "VEVTVF9UT0tFTl9OT19SRUFMX0lQX09SX1VBX0hFUkVfMDAwMQ==")
        #expect(auth?.key == "ign_test1234")     // field name contains "key" (hpKey)
        #expect(auth?.value == "deadbeefcafe0001") // field name contains "val" (hpVal)
    }

    @Test func parseAuthRejectsNonTokenEnvelope() {
        #expect(HLTBEndpoint.parseAuth(Data(#"{"nope":true}"#.utf8)) == nil)
        #expect(HLTBEndpoint.parseAuth(Data(#"<html/>"#.utf8)) == nil)
        // Since 2026-09-24 a token-only /init is a valid session (HLTBTokenOnlyAuthTests);
        // half a key/val pair is still an unknown shape.
        #expect(HLTBEndpoint.parseAuth(Data(#"{"token":"t","hpVal":"v"}"#.utf8)) == nil)
    }

    // MARK: - Payload

    @Test func searchPayloadCarriesTermsAndType() {
        let data = HLTBEndpoint.searchPayload(title: "Hollow Knight", auth: nil)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["searchType"] as? String == "games")
        #expect(json["searchTerms"] as? [String] == ["Hollow", "Knight"])
        #expect(json["size"] as? Int == HLTBEndpoint.searchPageSize)
    }

    @Test func searchPayloadInjectsAuthField() {
        let auth = HLTBEndpoint.Auth(token: "t", key: "ign_abc", value: "xyz")
        let json = try! JSONSerialization.jsonObject(
            with: HLTBEndpoint.searchPayload(title: "X", auth: auth)) as! [String: Any]
        #expect(json["ign_abc"] as? String == "xyz")   // body[hpKey] = hpVal
        // Without auth the dynamic field is absent.
        let plain = try! JSONSerialization.jsonObject(
            with: HLTBEndpoint.searchPayload(title: "X", auth: nil)) as! [String: Any]
        #expect(plain["ign_abc"] == nil)
    }

    @Test func searchRequestCarriesAuthHeaders() {
        let auth = HLTBEndpoint.Auth(token: "TKN", key: "ign_abc", value: "xyz")
        let req = HLTBEndpoint.searchRequest(title: "X", discovery: .fallback, auth: auth)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "x-auth-token") == "TKN")
        #expect(req.value(forHTTPHeaderField: "x-hp-key") == "ign_abc")
        #expect(req.value(forHTTPHeaderField: "x-hp-val") == "xyz")
    }

    @Test func authInitRequestTargetsInitPath() {
        let req = HLTBEndpoint.authInitRequest(discovery: .init(searchPath: "api/search/site"))
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString.hasPrefix("https://howlongtobeat.com/api/search/site/init?t=") == true)
    }

    // MARK: - DTO

    @Test func parseCandidatesMapsFieldsAndSeconds() throws {
        let data = try Fixtures.data("hltb-search-bloodborne.json")
        let candidates = try HLTBEndpoint.parseCandidates(data)
        #expect(!candidates.isEmpty)
        let c = candidates[0]
        #expect(c.id == 21262)
        #expect(c.name == "Bloodborne")
        #expect(c.releaseYear == 2015)
        #expect(c.mainSeconds == 115887)          // comp_main (seconds ≈ 32 h)
        #expect(c.mainExtraSeconds == 156000)     // comp_plus
        #expect(c.completionistSeconds == 270258) // comp_100
        #expect(c.platforms == ["PlayStation 4"])
    }

    @Test func parseEmptyResultYieldsNoCandidates() throws {
        let candidates = try HLTBEndpoint.parseCandidates(try Fixtures.data("hltb-search-empty.json"))
        #expect(candidates.isEmpty)
    }

    @Test func parseRejectsNonEnvelopeJSON() {
        #expect((try? HLTBEndpoint.parseCandidates(Data(#"{"nope":true}"#.utf8))) == nil)
        #expect(HLTBEndpoint.looksLikeSearchResponse(Data(#"<html></html>"#.utf8)) == false)
    }

    @Test func zeroTimesBecomeNil() throws {
        let data = Data(#"{"data":[{"game_id":1,"game_name":"X","comp_main":0,"comp_plus":0,"comp_100":0}]}"#.utf8)
        let c = try HLTBEndpoint.parseCandidates(data)[0]
        #expect(c.mainSeconds == nil)
        #expect(c.hasAnyTime == false)
    }
}
