import Foundation
import Testing
@testable import VGN

/// The pure system → platform table + skip list (PLAN §15), and a guard that every mapped
/// slug actually exists in the bundled platform catalogue.
struct BatoceraSystemsTests {

    @Test func mapsMainstreamSystemsToSlugs() {
        let expected: [String: String] = [
            "snes": "snes", "nes": "nes", "gb": "gb", "gbc": "gbc", "gba": "gba",
            "n64": "n64", "megadrive": "genesis", "mastersystem": "sms", "gamegear": "gamegear",
            "pcengine": "pcengine", "megacd": "segacd", "sega32x": "32x", "saturn": "saturn",
            "dreamcast": "dreamcast", "psx": "ps1", "ps2": "ps2", "psp": "psp",
            "gamecube": "gamecube", "wii": "wii", "wiiu": "wiiu", "nds": "ds", "3ds": "3ds",
            "msx1": "msx", "msx2": "msx", "colecovision": "colecovision", "jaguar": "jaguar",
            "wswan": "wonderswan", "wswanc": "wonderswancolor", "virtualboy": "virtualboy",
            "scummvm": "pc", "dos": "pc", "supergrafx": "pcengine",
        ]
        for (system, slug) in expected {
            #expect(BatoceraSystems.platformSlug(for: system) == slug, "\(system) → \(slug)")
        }
    }

    @Test func skipsArcadeAndPortSystems() {
        for system in ["mame", "mame2003", "fbneo", "daphne", "neogeo", "atomiswave",
                       "naomi", "chihiro", "cps1", "cps2", "cps3",
                       "prboom", "mrboom", "steam", "flatpak", "pygame", "sdlpop", "ports"] {
            #expect(BatoceraSystems.classify(system) == .skipped, "\(system) should be skipped")
        }
    }

    @Test func skipWinsOverAnySlug() {
        // neogeo has an AES slug but is an arcade romset → skipped, not mapped.
        #expect(BatoceraSystems.classify("neogeo") == .skipped)
    }

    @Test func unknownSystemsAreReportedNotGuessed() {
        for system in ["sg1000", "x68000", "pc98", "channelf", "does-not-exist"] {
            #expect(BatoceraSystems.classify(system) == .unknown, "\(system) should be unknown")
        }
    }

    @Test func everyMappedSlugExistsInThePlatformCatalogue() throws {
        let slugs = try Set(PlatformCatalog.entriesFromBundle().map(\.id))
        for slug in Set(BatoceraSystems.slugTable.values) {
            #expect(slugs.contains(slug), "platforms.json is missing slug '\(slug)'")
        }
    }
}
