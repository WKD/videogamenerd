import Foundation
import Testing
@testable import VGN

/// The ROM Catalogue browser model (PLAN §15): systems + counts, paging, filter / sort /
/// search reloads, the In-Library marker, and multi-selection action ids.
@MainActor
@Suite(.serialized)
struct RomCatalogueModelTests {

    private func seededStore() async throws -> RomCatalogStore {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        var snes: [RomCatalogEntry] = []
        for i in 0..<120 {
            let g = BatoceraGame(system: "snes", relativePath: "./s\(i).zip",
                                 name: String(format: "SNES %03d", i), genre: "Platform",
                                 gameTimeSeconds: i == 0 ? 5000 : 0, isFavorite: i == 1)
            snes.append(RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: "s\(i)"))
        }
        _ = try await store.syncSystem(system: "snes", entries: snes)
        let nesGame = BatoceraGame(system: "nes", relativePath: "./metroid.zip", name: "Metroid", genre: "Platform")
        _ = try await store.syncSystem(system: "nes", entries: [
            RomCatalogEntry.make(from: nesGame, platformID: "nes", libretroKey: "metroid")])
        return store
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsSystemsAndFirstPage() async throws {
        let store = try await seededStore()
        let model = RomCatalogueModel(catalog: store, pageSize: 50)
        model.start()
        await waitUntil { model.hasLoaded && !model.systems.isEmpty }
        #expect(model.systems.contains { $0.system == "snes" && $0.count == 120 })
        #expect(model.entries.count == 50)         // first page
        #expect(model.matchCount == 121)           // all systems, no filter
        #expect(model.hasMore)
    }

    @Test(.timeLimit(.minutes(1)))
    func pagingAppends() async throws {
        let store = try await seededStore()
        let model = RomCatalogueModel(catalog: store, pageSize: 50)
        model.selectedSystem = "snes"
        model.start()
        await waitUntil { model.hasLoaded && model.matchCount == 120 }
        #expect(model.entries.count == 50)
        model.loadMore()
        await waitUntil { model.entries.count == 100 }
        #expect(model.entries.count == 100)
    }

    @Test(.timeLimit(.minutes(1)))
    func filterAndSortAndSearchReload() async throws {
        let store = try await seededStore()
        let model = RomCatalogueModel(catalog: store, pageSize: 200)
        model.start()
        await waitUntil { model.hasLoaded }

        model.filter = .favourites
        await waitUntil { model.hasLoaded && model.entries.first?.name == "SNES 001" && model.matchCount == 1 }
        #expect(model.entries.map(\.name) == ["SNES 001"])

        model.filter = .played
        await waitUntil { model.entries.first?.name == "SNES 000" && model.matchCount == 1 }
        #expect(model.entries.map(\.name) == ["SNES 000"])

        model.filter = .all
        model.searchText = "metro"
        await waitUntil { model.entries.first?.name == "Metroid" && model.matchCount == 1 }
        #expect(model.entries.map(\.name) == ["Metroid"])
    }

    @Test func selectionActionIDs() {
        let store = RomCatalogStore(try! AppDatabase.inMemory())   // never queried here
        let model = RomCatalogueModel(catalog: store)
        model.selectOnly(5)
        #expect(model.actionIDs(for: 5) == [5])
        model.toggle(6)
        #expect(Set(model.actionIDs(for: 6)) == [5, 6])   // multi-selection acts on all
        #expect(model.actionIDs(for: 9) == [9])           // a row outside the selection acts alone
    }
}
