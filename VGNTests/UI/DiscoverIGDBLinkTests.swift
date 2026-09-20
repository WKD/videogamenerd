import Foundation
import Testing
@testable import VGN

/// The vault card "Open on IGDB" button (D7): only a matched entry (with an `igdb_id`) exposes a
/// URL; the action routes through the injected opener so NOTHING is opened during tests.
@MainActor
@Suite(.serialized)
struct DiscoverIGDBLinkTests {

    private func entry(_ id: Int64, name: String, igdbID: Int64?) -> RomCatalogEntry {
        var e = RomCatalogEntry(id: id, source: "batocera", system: "snes", platformID: "snes",
                                relativePath: "./\(name).zip", name: name, genre: "Platform")
        e.igdbID = igdbID
        return e
    }

    @Test func onlyMatchedEntriesExposeAURL() {
        let matched = entry(1, name: "Chrono Trigger", igdbID: 555)
        let unmatched = entry(2, name: "Mystery ROM", igdbID: nil)
        let url = try? #require(DiscoverModel.igdbURL(for: matched))
        #expect(url?.absoluteString.contains("igdb.com") == true)
        #expect(url?.absoluteString.contains("Chrono") == true)
        #expect(DiscoverModel.igdbURL(for: unmatched) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func openIGDBRoutesThroughTheInjectedOpener() async {
        final class Opened: @unchecked Sendable { var urls: [URL] = [] }
        let opened = Opened()
        let backend = FakeDiscoverBackend(ranked: [], pool: [])
        let model = DiscoverModel(backend: backend, openURL: { opened.urls.append($0) })

        model.openIGDB(entry(1, name: "Secret of Mana", igdbID: 900))
        #expect(opened.urls.count == 1)
        #expect(opened.urls.first?.absoluteString.contains("Secret") == true)

        // An unmatched entry opens nothing.
        model.openIGDB(entry(2, name: "Unknown", igdbID: nil))
        #expect(opened.urls.count == 1)
    }
}
