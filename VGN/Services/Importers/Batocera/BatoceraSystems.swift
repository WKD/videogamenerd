import Foundation

/// The pure Batocera-system → VGN-platform table + the skip list (PLAN §15). Foundation
/// only, table-driven, no I/O. A system is one of three things:
///  - **mapped** to a VGN platform slug (present in `platforms.json`);
///  - **skipped** — an arcade romset (MAME, FBNeo, Neo-Geo…) or a non-collection "system"
///    (a port/engine/launcher such as `prboom`, `steam`, `flatpak`);
///  - **unknown** — reported in the sync summary, never guessed onto a slug.
///
/// Slugs are permanent DB keys, so an unrecognised system is surfaced for the owner rather
/// than invented. The skip list is a constant here; PLAN §15 phase 2 makes it overridable
/// from Settings.
enum BatoceraSystems {

    /// What one Batocera system folder resolves to.
    enum Classification: Equatable, Sendable {
        case mapped(slug: String)
        case skipped
        case unknown
    }

    /// Batocera system folder (lowercased) → VGN platform slug. Aliases fold to one slug
    /// (`megadrive`/`genesis` → `genesis`; `msx1`/`msx2` → `msx`). Every value here must
    /// exist in `platforms.json`.
    static let slugTable: [String: String] = [
        // Nintendo
        "nes": "nes", "famicom": "nes", "fds": "nes",
        "snes": "snes", "sfc": "snes", "satellaview": "snes", "sufami": "snes",
        "n64": "n64", "n64dd": "n64",
        "gb": "gb", "gameboy": "gb", "sgb": "gb",
        "gbc": "gbc", "gba": "gba",
        "nds": "ds", "ds": "ds",
        "3ds": "3ds",
        "gamecube": "gamecube", "gc": "gamecube",
        "wii": "wii", "wiiu": "wiiu",
        "virtualboy": "virtualboy", "vboy": "virtualboy",
        "gameandwatch": "gameandwatch", "gw": "gameandwatch",
        // Sega
        "megadrive": "genesis", "genesis": "genesis", "megadrive-japan": "genesis",
        "mastersystem": "sms", "sms": "sms",
        "gamegear": "gamegear",
        "sega32x": "32x", "32x": "32x", "sega32x-japan": "32x",
        "megacd": "segacd", "segacd": "segacd", "megacd-japan": "segacd",
        "saturn": "saturn", "dreamcast": "dreamcast",
        // Sony
        "psx": "ps1", "playstation": "ps1",
        "ps2": "ps2", "psp": "psp",
        // Microsoft
        "xbox": "xbox", "xbox360": "xbox360",
        // NEC
        "pcengine": "pcengine", "tg16": "pcengine", "turbografx16": "pcengine",
        "supergrafx": "pcengine", "pcfx": "pcengine",
        "pcenginecd": "pcenginecd", "pcecd": "pcenginecd", "tg-cd": "pcenginecd",
        // Atari
        "atari2600": "atari2600", "atari5200": "atari5200", "atari7800": "atari7800",
        "jaguar": "jaguar", "jaguarcd": "jaguar",
        "lynx": "lynx", "atarilynx": "lynx",
        "atarist": "atarist",
        // Bandai / SNK handhelds
        "wswan": "wonderswan", "wonderswan": "wonderswan",
        "wswanc": "wonderswancolor", "wonderswancolor": "wonderswancolor",
        "ngp": "neogeopocket", "ngpc": "neogeopocketcolor",
        // Other consoles
        "3do": "3do", "cdi": "cdi",
        "colecovision": "colecovision", "intellivision": "intellivision", "vectrex": "vectrex",
        // Computers
        "msx1": "msx", "msx": "msx", "msx2": "msx", "msx2+": "msx", "msxturbor": "msx",
        "c64": "c64", "amstradcpc": "cpc", "gx4000": "cpc",
        "zxspectrum": "zxspectrum", "spectrum": "zxspectrum",
        "apple2": "appleii",
        "amiga500": "amiga", "amiga1200": "amiga", "amigacd32": "amiga", "amigacdtv": "amiga",
        "amiga": "amiga",
        // Engines / DOS the owner really plays → the PC platform (PLAN §15)
        "scummvm": "pc", "dos": "pc", "pc": "pc", "windows": "pc",
    ]

    /// Arcade romsets — never a personal collection, always skipped (PLAN §15). Prefix
    /// `cps` is handled in ``isSkipped(_:)``.
    static let arcadeSkip: Set<String> = [
        "mame", "mame2003", "mame2010", "mame2015", "fbneo", "fba", "fbalpha",
        "daphne", "naomi", "naomi2", "atomiswave", "neogeo", "model2", "model3",
        "namco2x6", "namco22", "chihiro", "triforce", "hikaru", "gaelco", "segastv",
        "stv", "midwunit", "midwvunit", "cave", "atari_lynx_arcade",
    ]

    /// Non-collection "systems": ports, engines, launchers and shells (PLAN §15). These
    /// carry no ROM library.
    static let nonCollectionSkip: Set<String> = [
        "prboom", "mrboom", "cavestory", "devilutionx", "pygame", "flatpak", "steam",
        "moonlight", "flash", "ports", "kodi", "library", "lutro", "sdlpop",
        "odcommander", "cannonball", "cdogs", "cgenius", "corsixth", "dxx-rebirth",
        "easyrpg", "ecwolf", "eduke32", "etlegacy", "fallout1-ce", "fallout2-ce",
        "abuse", "doom3", "quake", "quake2", "quake3", "openbor", "solarus", "tyrquake",
        "vircon32", "wasm4", "arduboy", "tic80", "uzebox", "lowresnx", "pico8",
        "windows_installers",
    ]

    /// The default editable skip list shown in Settings ▸ Batocera (PLAN §15 phase 2):
    /// the built-in arcade romsets + non-collection ports/engines, sorted. The owner may
    /// add or remove entries; the numbered romset **families** (`mame*`, `cps*`) are always
    /// skipped regardless (``isArcadeFamily(_:)``) so a stray `mame2010` can never flood in.
    static let defaultSkipList: [String] = Array(arcadeSkip.union(nonCollectionSkip)).sorted()

    /// Classify one system folder name against the built-in skip list (existing behaviour).
    static func classify(_ system: String) -> Classification {
        classify(system, skip: arcadeSkip.union(nonCollectionSkip))
    }

    /// Classify one system folder name against an **explicit** skip set (PLAN §15 phase 2 —
    /// the owner's editable skip list). `skip` is the authoritative list of exact system
    /// folder names to skip; the arcade romset *families* (`mame*`, `cps*`) are always
    /// skipped on top of it, so removing them from the list can never un-skip a `mame2003`.
    static func classify(_ system: String, skip: Set<String>) -> Classification {
        let key = system.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return .unknown }
        if isArcadeFamily(key) || skip.contains(key) { return .skipped }
        if let slug = slugTable[key] { return .mapped(slug: slug) }
        return .unknown
    }

    /// The always-skip arcade romset families identified by prefix (`mame2003`, `cps2` …),
    /// which are never a personal collection whatever the editable list says.
    static func isArcadeFamily(_ system: String) -> Bool {
        let key = system.lowercased()
        return key.hasPrefix("cps") || key.hasPrefix("mame")
    }

    /// The VGN slug for a system, or nil when skipped / unknown.
    static func platformSlug(for system: String) -> String? {
        if case let .mapped(slug) = classify(system) { return slug }
        return nil
    }

    /// Whether a system is on the skip list (arcade romset or non-collection port/engine).
    static func isSkipped(_ system: String) -> Bool {
        let key = system.lowercased()
        if arcadeSkip.contains(key) || nonCollectionSkip.contains(key) { return true }
        if key.hasPrefix("cps") { return true }             // cps1 / cps2 / cps3
        if key.hasPrefix("mame") { return true }            // mame20xx variants
        return false
    }
}
