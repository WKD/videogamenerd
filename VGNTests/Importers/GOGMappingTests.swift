import Foundation
import Testing
@testable import VGN

/// Pure ``GOGMapping``: platform rule, noise reasons, year extraction (PLAN §14.3), on
/// the synthetic product pages.
@Suite struct GOGMappingTests {

    private func products(_ name: String) throws -> [GOGProduct] {
        try JSONDecoder().decode(GOGProductsPage.self, from: try Fixtures.data(name)).products
    }

    @Test func platformRuleMacWhenAvailableElsePC() throws {
        let p1 = try products("gog-products-page1.json")
        let quest = p1.first { $0.id == 100001 }!       // Win + Mac
        let racer = p1.first { $0.id == 100002 }!       // Win only
        #expect(GOGMapping.platform(for: quest, policy: .macWhenAvailable) == "mac")
        #expect(GOGMapping.platform(for: racer, policy: .macWhenAvailable) == "pc")
        // Always-PC forces pc even for a Mac title.
        #expect(GOGMapping.platform(for: quest, policy: .alwaysPC) == "pc")
    }

    @Test func linuxOnlyMapsToPC() throws {
        let linux = try products("gog-products-page2.json").first { $0.id == 100005 }!
        #expect(GOGMapping.platform(for: linux, policy: .macWhenAvailable) == "pc")
    }

    @Test func noiseReasons() throws {
        let all = try products("gog-products-page1.json") + products("gog-products-page2.json")
            + products("gog-products-page3.json")
        func reason(_ id: Int64) -> ImportIgnoreReason? {
            GOGMapping.ignoreReason(for: all.first { $0.id == id }!)
        }
        #expect(reason(100001) == nil)                       // ordinary game
        #expect(reason(100003) == .soundtrackOrGoodies)      // "Soundtrack"
        #expect(reason(100004) == .dlcOrExpansion)           // "Expansion Pack" / DLC
        #expect(reason(100006) == .hidden)                   // isHidden
        #expect(reason(100007) == .demoOrPrologue)           // "Demo"
        #expect(reason(100010) == .notAGame)                 // isGame == false
    }

    @Test func stagingRowCarriesYearAndSignals() throws {
        let quest = try products("gog-products-page1.json").first { $0.id == 100001 }!
        let row = GOGMapping.stagingRow(for: quest, policy: .macWhenAvailable)
        #expect(row.source == ImportSourceID.gog)
        #expect(row.externalID == "100001")
        #expect(row.platform == "mac")
        #expect(row.signals == [.owned])
        #expect(row.releaseYear == 2018)
        #expect(row.ignoreReason == nil)
    }

    @Test func yearExtractionAcrossFormats() throws {
        // String "2018-05-01", unix 1320969600 (2011), object {date:"2016-03-03"}, and null.
        let p1 = try products("gog-products-page1.json")
        let p2 = try products("gog-products-page2.json")
        let p3 = try products("gog-products-page3.json")
        #expect(p1.first { $0.id == 100001 }!.releaseDate?.year == 2018)   // string
        #expect(p1.first { $0.id == 100002 }!.releaseDate?.year == 2011)   // unix
        #expect(p2.first { $0.id == 100005 }!.releaseDate?.year == 2016)   // object
        #expect(p3.first { $0.id == 100009 }!.releaseDate == nil)          // absent
    }

    @Test func mappingCountsNoiseVsGames() throws {
        let all = try products("gog-products-page1.json") + products("gog-products-page2.json")
            + products("gog-products-page3.json")
        let rows = GOGMapping.stagingRows(for: all, policy: .macWhenAvailable)
        #expect(rows.count == 10)
        #expect(rows.filter { $0.ignoreReason == nil }.count == 5)   // games
        #expect(rows.filter { $0.ignoreReason != nil }.count == 5)   // noise
    }
}
