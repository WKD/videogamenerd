import Foundation

/// Maps VGN platform **slugs** (`ps3`, `pc`, `snes`, `switch`…) to the platform **names**
/// HowLongToBeat prints in a candidate's `profile_platform` list (PLAN §5.3, D2). Pure
/// Foundation, so it lives in the Matching layer and is shared by the pure ``HLTBMatcher``
/// (platform overlap as a tie-breaker) and the picker UI (emphasising the matching rows).
///
/// A slug maps to one **canonical** HLTB name plus tolerated aliases (HLTB has renamed a
/// few over the years). Reverse lookup normalises both sides (case / punctuation folded),
/// so "Xbox Series X/S" ≈ "Xbox Series X|S". Slugs HLTB does not know simply have no entry
/// and never participate — the tie-breaker is best-effort and never blocks a match.
///
/// The canonical spellings are kept identical to what the recorded fixtures contain; a
/// lint test (`HLTBPlatformMapTests`) walks every fixture's `profile_platform` and asserts
/// each name a VGN slug covers round-trips to that slug with the fixture's exact spelling.
enum HLTBPlatformMap {
    /// slug → HLTB names (first is canonical). Covers the slugs in `platforms.json` that
    /// HLTB catalogues; obscure ones (WonderSwan, CD-i, Vectrex…) are intentionally absent.
    static let namesBySlug: [String: [String]] = [
        // Sony
        "ps5": ["PlayStation 5"],
        "ps4": ["PlayStation 4"],
        "ps3": ["PlayStation 3"],
        "ps2": ["PlayStation 2"],
        "ps1": ["PlayStation"],
        "vita": ["PlayStation Vita"],
        "psp": ["PlayStation Portable", "PSP"],
        // Nintendo
        "switch2": ["Nintendo Switch 2"],
        "switch": ["Nintendo Switch"],
        "wiiu": ["Wii U"],
        "wii": ["Wii"],
        "gamecube": ["Nintendo GameCube", "GameCube"],
        "n64": ["Nintendo 64"],
        "snes": ["Super Nintendo Entertainment System", "SNES", "Super Nintendo"],
        "nes": ["Nintendo Entertainment System", "NES"],
        "3ds": ["Nintendo 3DS"],
        "ds": ["Nintendo DS"],
        "gba": ["Game Boy Advance"],
        "gbc": ["Game Boy Color"],
        "gb": ["Game Boy"],
        // Sega
        "dreamcast": ["Dreamcast"],
        "saturn": ["Sega Saturn"],
        "32x": ["Sega 32X"],
        "segacd": ["Sega CD"],
        "genesis": ["Genesis", "Sega Genesis", "Sega Mega Drive"],
        "sms": ["Sega Master System"],
        "gamegear": ["Sega Game Gear", "Game Gear"],
        // Microsoft
        "xboxseries": ["Xbox Series X/S", "Xbox Series X|S"],
        "xboxone": ["Xbox One"],
        "xbox360": ["Xbox 360"],
        "xbox": ["Xbox"],
        // Computers
        "pc": ["PC"],
        "mac": ["Mac"],
        "amiga": ["Amiga", "Commodore Amiga"],
        "atarist": ["Atari ST"],
        "c64": ["Commodore 64", "Commodore C64/128/MAX"],
        "cpc": ["Amstrad CPC"],
        "msx": ["MSX"],
        "zxspectrum": ["ZX Spectrum", "Sinclair ZX Spectrum"],
        "appleii": ["Apple II"],
        // Other
        "arcade": ["Arcade"],
        "jaguar": ["Atari Jaguar", "Jaguar"],
        "atari7800": ["Atari 7800"],
        "atari5200": ["Atari 5200"],
        "atari2600": ["Atari 2600"],
        "lynx": ["Atari Lynx"],
        "pcengine": ["TurboGrafx-16", "PC Engine"],
        "pcenginecd": ["TurboGrafx-CD", "PC Engine CD"],
        "neogeo": ["Neo Geo", "Neo Geo AES"],
        "3do": ["3DO"],
        "colecovision": ["ColecoVision"],
        "intellivision": ["Intellivision"],
    ]

    /// The canonical HLTB name for a slug (for a UI label), or nil when HLTB is unaware.
    static func canonicalName(forSlug slug: String) -> String? {
        namesBySlug[slug]?.first
    }

    /// Every HLTB name a slug may appear as.
    static func names(forSlug slug: String) -> [String] {
        namesBySlug[slug] ?? []
    }

    /// The VGN slug an HLTB platform name maps to, or nil. Normalises case + punctuation
    /// so "Xbox Series X/S" and "Xbox Series X|S" both resolve.
    static func slug(forHLTBName name: String) -> String? {
        let key = fold(name)
        return foldedIndex[key]
    }

    /// The subset of `candidatePlatforms` that intersect the library game's `slugs`
    /// (as HLTB name strings, for emphasis in the picker). Order preserved.
    static func overlapping(candidatePlatforms: [String], librarySlugs: Set<String>) -> [String] {
        candidatePlatforms.filter { name in
            if let slug = slug(forHLTBName: name) { return librarySlugs.contains(slug) }
            return false
        }
    }

    /// True when any of a candidate's platforms maps to one of the library game's slugs.
    static func intersects(candidatePlatforms: [String], librarySlugs: Set<String>) -> Bool {
        guard !librarySlugs.isEmpty else { return false }
        return !overlapping(candidatePlatforms: candidatePlatforms, librarySlugs: librarySlugs).isEmpty
    }

    // MARK: - Folding

    /// A reverse index: folded HLTB name → slug (first slug wins on the rare collision).
    private static let foldedIndex: [String: String] = {
        var out: [String: String] = [:]
        for (slug, names) in namesBySlug {
            for name in names {
                let key = fold(name)
                if out[key] == nil { out[key] = slug }
            }
        }
        return out
    }()

    /// Fold a platform name for comparison: lowercase, collapse `/ | \` to one separator,
    /// drop other punctuation, squeeze whitespace.
    static func fold(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).unicodeScalars {
            if CharacterSet.alphanumerics.contains(u) {
                scalars.append(u)
            } else if u == "/" || u == "|" || u == "\\" {
                scalars.append(" ")   // "X/S" ≈ "X|S"
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars).split(whereSeparator: { $0 == " " }).joined(separator: " ")
    }
}
