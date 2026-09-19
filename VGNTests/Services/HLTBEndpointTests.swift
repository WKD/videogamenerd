import Foundation
import Testing
@testable import VGN

/// The isolated HLTB request/response mechanics (PLAN §5.3): endpoint discovery
/// parsing, the search payload, and DTO decoding — all pure, driven by the committed
/// synthetic fixtures built from the reference client's documented shapes.
@Suite struct HLTBEndpointTests {

    @Test func scriptPathsExtractedAndAppChunkFirst() throws {
        let html = try String(decoding: Fixtures.data("hltb-discovery-home.html"), as: UTF8.self)
        let paths = HLTBEndpoint.scriptPaths(inHTML: html)
        #expect(paths.count == 2)
        // The _app chunk (which carries the fetch) is tried first.
        #expect(paths.first?.contains("_app") == true)
    }

    @Test func discoveryResolvesConcatenatedToken() throws {
        let js = try String(decoding: Fixtures.data("hltb-discovery-app.js"), as: UTF8.self)
        let d = HLTBEndpoint.resolveDiscovery(fromScript: js)
        #expect(d?.searchPath == "api/seek/abcd12ef")
        #expect(d?.searchURL.absoluteString == "https://howlongtobeat.com/api/seek/abcd12ef")
    }

    @Test func discoveryHandlesBareLiteralEndpoint() {
        let js = #"var f=function(a){return fetch("/api/s/",{method:"POST",body:a})};"#
        let d = HLTBEndpoint.resolveDiscovery(fromScript: js)
        #expect(d?.searchPath == "api/s/")
    }

    @Test func discoveryHandlesPlusConcatenation() {
        let js = #"fetch("/api/seek/"+"aa"+"bb",{method:"POST"})"#
        let d = HLTBEndpoint.resolveDiscovery(fromScript: js)
        #expect(d?.searchPath == "api/seek/aabb")
    }

    @Test func discoveryFailsGracefullyOnUnrelatedScript() {
        let d = HLTBEndpoint.resolveDiscovery(fromScript: "console.log('no endpoint here');")
        #expect(d == nil)
    }

    @Test func searchPayloadCarriesTermsAndType() {
        let data = HLTBEndpoint.searchPayload(title: "Hollow Knight", discovery: .fallback)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["searchType"] as? String == "games")
        #expect(json["searchTerms"] as? [String] == ["Hollow", "Knight"])
        #expect(json["size"] as? Int == HLTBEndpoint.searchPageSize)
    }

    @Test func parseCandidatesMapsFieldsAndSeconds() throws {
        let data = try Fixtures.data("hltb-search-bloodborne.json")
        let candidates = try HLTBEndpoint.parseCandidates(data)
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(c.id == 2600)
        #expect(c.name == "Bloodborne")
        #expect(c.releaseYear == 2015)
        #expect(c.mainSeconds == 115200)          // comp_main
        #expect(c.mainExtraSeconds == 154800)     // comp_plus
        #expect(c.completionistSeconds == 259200) // comp_100
        #expect(c.platforms == ["PlayStation 4", "PlayStation 5"])
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
