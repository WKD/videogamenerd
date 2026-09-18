import Foundation
import Testing
@testable import VGN

/// A small catalogue used across the IGDB/cover tests, plus the real bundled one.
enum TestCatalog {
    static let entries: [PlatformCatalogEntry] = [
        .init(id: "ps4", name: "PlayStation 4", short: "PS4", manufacturer: "Sony", group: "Sony", kind: "console", generation: 8, igdbIDs: [48], libretroRepo: nil, sort: 20),
        .init(id: "ps3", name: "PlayStation 3", short: "PS3", manufacturer: "Sony", group: "Sony", kind: "console", generation: 7, igdbIDs: [9], libretroRepo: "Sony_-_PlayStation_3", sort: 30),
        .init(id: "ps2", name: "PlayStation 2", short: "PS2", manufacturer: "Sony", group: "Sony", kind: "console", generation: 6, igdbIDs: [8], libretroRepo: "Sony_-_PlayStation_2", sort: 40),
        .init(id: "ps1", name: "PlayStation", short: "PS1", manufacturer: "Sony", group: "Sony", kind: "console", generation: 5, igdbIDs: [7], libretroRepo: "Sony_-_PlayStation", sort: 50),
        .init(id: "pc", name: "PC", short: "PC", manufacturer: "PC", group: "Computer", kind: "computer", generation: nil, igdbIDs: [6, 13], libretroRepo: nil, sort: 10),
        .init(id: "snes", name: "SNES", short: "SNES", manufacturer: "Nintendo", group: "Nintendo", kind: "console", generation: 4, igdbIDs: [19, 58], libretroRepo: "Nintendo_-_Super_Nintendo_Entertainment_System", sort: 80),
        .init(id: "dreamcast", name: "Dreamcast", short: "DC", manufacturer: "Sega", group: "Sega", kind: "console", generation: 6, igdbIDs: [23], libretroRepo: "Sega_-_Dreamcast", sort: 60),
    ]
    static let catalog = PlatformCatalog(entries: entries)
}

struct PlatformCatalogTests {

    @Test("Maps IGDB platform ids to VGN slugs, including PC = [6, 13]")
    func mapping() {
        let c = TestCatalog.catalog
        #expect(c.slug(forIGDBID: 48) == "ps4")
        #expect(c.slug(forIGDBID: 9) == "ps3")
        #expect(c.slug(forIGDBID: 6) == "pc")
        #expect(c.slug(forIGDBID: 13) == "pc")     // both DOS and Windows fold to PC
        #expect(c.slug(forIGDBID: 19) == "snes")
        #expect(c.slug(forIGDBID: 58) == "snes")
        #expect(c.slug(forIGDBID: 9999) == nil)
    }

    @Test("Multi-id mapping dedupes and preserves order")
    func multiMapping() {
        let c = TestCatalog.catalog
        #expect(c.slugs(forIGDBIDs: [6, 13]) == ["pc"])     // both → pc, deduped
        #expect(c.slugs(forIGDBIDs: [48, 9, 48]) == ["ps4", "ps3"])
        #expect(c.slugs(forIGDBIDs: [9999]) == [])
    }

    @Test("Exposes libretro repo per slug")
    func libretroRepo() {
        let c = TestCatalog.catalog
        #expect(c.libretroRepo(forSlug: "dreamcast") == "Sega_-_Dreamcast")
        #expect(c.libretroRepo(forSlug: "ps4") == nil)      // modern platform, no retro repo
    }

    @Test("Loads the real bundled platforms.json (61 platforms, PC = [6,13])")
    func bundled() throws {
        let catalog = try PlatformCatalog.loadFromBundle()
        #expect(catalog.entries.count == 61)
        #expect(catalog.slug(forIGDBID: 6) == "pc")
        #expect(catalog.slug(forIGDBID: 13) == "pc")
        #expect(catalog.slug(forIGDBID: 48) == "ps4")
        #expect(catalog.libretroRepo(forSlug: "ps1") == "Sony_-_PlayStation")
    }
}
