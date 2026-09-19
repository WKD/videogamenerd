import Foundation

/// Pure Delicious-row → staging-row mapping (PLAN §5.5). Foundation only, no I/O, so it
/// is table-driven and trivially testable:
///  - platform labels → VGN slugs, with the PC/Mac hybrid-disc policy GOG already uses;
///  - **title cleaning for matching only** (the original title is always kept & shown):
///    strip platform / media / edition / bundle noise, extract the edition;
///  - release year as the IGDB tie-breaker; acquired date + edition for the copy.
enum DeliciousMapping {

    // MARK: - Platform

    /// What one raw Delicious platform label maps to.
    enum PlatformClass: Equatable {
        case slug(String)   // a concrete VGN console/handheld slug (ps3, wii, n64…)
        case windows        // any "Windows …" → contributes `pc`
        case mac            // Macintosh / Mac OS X → contributes `mac`
    }

    /// Exact (lowercased) label → class. Windows is handled by prefix in ``classify``.
    static let platformTable: [String: PlatformClass] = [
        "playstation 3": .slug("ps3"), "playstation 2": .slug("ps2"),
        "playstation": .slug("ps1"), "playstation portable": .slug("psp"),
        "nintendo wii": .slug("wii"), "wii": .slug("wii"),
        "nintendo gamecube": .slug("gamecube"), "gamecube": .slug("gamecube"),
        "nintendo 64": .slug("n64"),
        "nintendo ds": .slug("ds"), "nintendo dsi": .slug("ds"),
        "nintendo 3ds": .slug("3ds"),
        "game boy advance": .slug("gba"), "game boy color": .slug("gbc"), "game boy": .slug("gb"),
        "super nintendo": .slug("snes"), "nintendo entertainment system": .slug("nes"),
        "sega dreamcast": .slug("dreamcast"), "dreamcast": .slug("dreamcast"),
        "sega saturn": .slug("saturn"), "sega genesis": .slug("genesis"),
        "sega mega drive": .slug("genesis"),
        "xbox 360": .slug("xbox360"), "xbox one": .slug("xboxone"), "xbox": .slug("xbox"),
        "macintosh": .mac, "mac os x": .mac, "mac os": .mac, "mac": .mac,
    ]

    /// Classify one raw label; nil ⇒ not recognised (row needs a platform pick).
    static func classify(_ raw: String) -> PlatformClass? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        if key.hasPrefix("windows") || key == "pc" || key.hasPrefix("microsoft windows") {
            return .windows
        }
        return platformTable[key]
    }

    /// The resolved platform for a game under a policy.
    struct PlatformResolution: Equatable {
        /// The VGN slug the row lands on, or nil when nothing recognised (needs a pick).
        var slug: String?
        /// A Mac build exists (Mac-only or PC/Mac hybrid) — lets the review sheet re-map
        /// on the policy switch.
        var macAvailable: Bool
        /// Nothing recognised → the review row shows *New* with a platform pick required.
        var needsPick: Bool
    }

    /// Resolve a game's platform list to one slug under `policy`. Console labels win
    /// (a physical console game is never re-mapped by the PC/Mac switch); a PC/Mac
    /// hybrid follows the policy exactly as GOG's does.
    static func resolvePlatform(_ labels: [String], policy: ImportPlatformPolicy) -> PlatformResolution {
        var consoleSlugs: [String] = []
        var hasWindows = false
        var hasMac = false
        for label in labels {
            switch classify(label) {
            case .slug(let s): if !consoleSlugs.contains(s) { consoleSlugs.append(s) }
            case .windows: hasWindows = true
            case .mac: hasMac = true
            case nil: break
            }
        }

        if let console = consoleSlugs.first {
            return PlatformResolution(slug: console, macAvailable: false, needsPick: false)
        }
        if hasMac || hasWindows {
            let macAvailable = hasMac
            let slug = policy == .alwaysPC ? "pc" : (hasMac ? "mac" : "pc")
            return PlatformResolution(slug: slug, macAvailable: macAvailable, needsPick: false)
        }
        return PlatformResolution(slug: nil, macAvailable: false, needsPick: true)
    }

    // MARK: - Title cleaning + edition extraction

    /// An edition phrase to recognise (FR/EN), with the canonical label stored on the
    /// copy. Ordered longest-first so the most specific phrase wins.
    static let editionPhrases: [(needle: String, label: String)] = [
        ("game of the year edition", "Game of the Year"), ("game of the year", "Game of the Year"),
        ("edition collector", "Collector's Edition"), ("collector's edition", "Collector's Edition"),
        ("collectors edition", "Collector's Edition"), ("collector edition", "Collector's Edition"),
        ("edition limitee", "Limited Edition"), ("limited edition", "Limited Edition"),
        ("edition speciale", "Special Edition"), ("special edition", "Special Edition"),
        ("edition definitive", "Definitive Edition"), ("definitive edition", "Definitive Edition"),
        ("director's cut", "Director's Cut"), ("directors cut", "Director's Cut"),
        ("standard edition", "Standard Edition"),
        ("greatest hits", "Greatest Hits"),
        ("player's choice", "Player's Choice"), ("players choice", "Player's Choice"),
        ("platinum", "Platinum"), ("essentials", "Essentials"),
        ("goty", "Game of the Year"),
    ]

    /// Multi-word media / platform noise removed for matching (before the word filter).
    static let multiWordNoise = [
        "dvd rom", "cd rom", "gd rom", "blu ray", "cartouche de jeu",
        "xbox 360", "xbox one",
    ]

    /// Single-word platform / media tags removed for matching (whole-word, case &
    /// diacritic insensitive).
    static let singleWordNoise: Set<String> = [
        "ps3", "ps2", "ps1", "psx", "psp", "vita",
        // NOT "wii" / "wii u" / "ds" / "3ds": they are part of real titles ("Mario Kart
        // Wii", "New Super Mario Bros. Wii", "Wii Sports", "Mario Kart DS") — stripping
        // them matched the wrong game. The matcher is platform-constrained anyway.
        "gamecube", "ngc", "n64",
        "gba", "gbc", "gb", "snes", "nes",
        "xbox", "xbox360", "dreamcast",
        "pc", "mac", "windows",
        "dvd-rom", "cd-rom", "dvdrom", "cdrom", "bluray", "blu-ray", "umd", "gd-rom", "cartouche",
    ]

    /// Clean a raw Delicious title for **matching**, returning the scrubbed title and any
    /// extracted edition. The scrubbed form is never shown — the original stays on the row.
    static func clean(_ raw: String) -> (title: String, edition: String?) {
        // 1. Drop a bundle tail: "Donkey Kong 64 + Memory Expansion Pack" → "Donkey Kong 64".
        var work = raw
        if let plus = work.range(of: " + ") { work = String(work[..<plus.lowerBound]) }

        // 2. Extract the first edition phrase (word-bounded), remove it.
        var edition: String? = nil
        for (needle, label) in editionPhrases {
            if let r = wordRange(of: needle, in: work) {
                edition = label
                work.removeSubrange(r)
                break
            }
        }

        // 3. Remove multi-word media/platform phrases.
        for phrase in multiWordNoise { work = removeAllWordBounded(phrase, from: work) }

        // 4. Drop single-word platform/media tags at word level (punctuation preserved).
        let kept = work.split(separator: " ", omittingEmptySubsequences: true).filter { word in
            !singleWordNoise.contains(foldLower(String(word)))
        }
        work = tidy(kept.joined(separator: " "))
        if work.isEmpty { work = tidy(raw) }   // never reduce to nothing
        return (work, edition)
    }

    // MARK: - Cleaning helpers

    static func foldLower(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// The first word-bounded, case/diacritic-insensitive occurrence of `needle` in `s`.
    static func wordRange(of needle: String, in s: String) -> Range<String.Index>? {
        var from = s.startIndex
        while from < s.endIndex,
              let r = s.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                              range: from..<s.endIndex) {
            if isWordBoundary(before: r.lowerBound, after: r.upperBound, in: s) { return r }
            from = s.index(after: r.lowerBound)
        }
        return nil
    }

    /// Remove every word-bounded occurrence of `phrase`, replacing each with a space.
    static func removeAllWordBounded(_ phrase: String, from s: String) -> String {
        var s = s
        var guardCount = 0
        while guardCount < 32, let r = wordRange(of: phrase, in: s) {
            s.replaceSubrange(r, with: " ")
            guardCount += 1
        }
        return s
    }

    /// A word boundary exists on both sides when the neighbouring character is not a
    /// letter/number (so "ds" in "Kids" is not a match, but trailing "DS" is).
    static func isWordBoundary(before lower: String.Index, after upper: String.Index, in s: String) -> Bool {
        let leftOK: Bool = lower == s.startIndex || !isWordChar(s[s.index(before: lower)])
        let rightOK: Bool = upper == s.endIndex || !isWordChar(s[upper])
        return leftOK && rightOK
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    // MARK: - Staging row

    /// Map one ``DeliciousGame`` to a staging row (owned, physical). `name` keeps the
    /// original title (shown); `matchTitle` carries the cleaned form (matched); the
    /// extracted edition (or the store's `editions` field) and acquired date ride along
    /// as transients so the commit can land them on the copy.
    static func stagingRow(for game: DeliciousGame, policy: ImportPlatformPolicy) -> ImportStagingRow {
        let resolution = resolvePlatform(game.platforms, policy: policy)
        let cleaned = clean(game.title)
        let edition = cleaned.edition ?? normalizedStoreEdition(game.editions)
        // Match on the cleaned title only when it actually differs from the original.
        let matchTitle = cleaned.title.caseInsensitiveCompare(game.title) == .orderedSame
            ? nil : cleaned.title
        return ImportStagingRow(
            source: ImportSourceID.delicious,
            externalID: game.uuid,
            name: game.title,
            platform: resolution.slug,
            signals: [.owned],
            releaseYear: game.publishYear,
            macAvailable: resolution.macAvailable,
            matchTitle: matchTitle,
            edition: edition,
            acquiredAt: game.catalogedAt)
    }

    static func stagingRows(for games: [DeliciousGame], policy: ImportPlatformPolicy) -> [ImportStagingRow] {
        games.map { stagingRow(for: $0, policy: policy) }
    }

    /// A store edition string worth keeping (drop empties / a bare "Standard Edition"
    /// is kept as-is since the owner recorded it).
    static func normalizedStoreEdition(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// Collapse whitespace and trim dangling separator punctuation ( : - , ) left by
    /// removals, so "Heavy Rain  -  " → "Heavy Rain".
    static func tidy(_ s: String) -> String {
        var t = s
        // Collapse runs of separators/space: " : - " → " - ".
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*[:\-–]\s*[:\-–]\s*"#, with: " - ", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n:-–,;/"))
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
