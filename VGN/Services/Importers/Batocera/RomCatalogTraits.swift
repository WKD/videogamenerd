import Foundation

/// Turns a catalogue entry's ScreenScraper metadata into the same ``GameTrait`` vocabulary
/// the recommendation engine consumes (PLAN §15 phase-2 groundwork, §7b). Pure, Foundation
/// only, no I/O. The gamelist already carries genre / family / developer / year, so a
/// catalogue game is taste-scorable **offline**, with no IGDB call (PLAN §15 survey point 2).
///
/// ScreenScraper genres are hierarchical, `"Top / Sub"` (`"Shoot'em Up / Horizontal"`,
/// `"Role Playing Game / Action RPG"`). The top segment maps onto an IGDB-style genre or
/// theme name via ``genreMap`` (so it matches a ranked game's `.genre` / `.theme` traits);
/// every segment is also emitted as a `.keyword` so an unmapped nuance still contributes.
/// `family` → `.franchise`, `developer` → `.developer`, the release year → `.decade`.
enum RomCatalogTraits {

    /// A resolved primary trait for a ScreenScraper top-level genre.
    struct GenreMapping: Equatable, Sendable {
        var kind: GameTraitKind    // .genre or .theme
        var value: String
    }

    /// ScreenScraper top-level genre (lowercased) → IGDB-style genre/theme. Values match the
    /// names IGDB enrichment stores (`genres.name` / theme traits), so affinity matching works.
    static let genreMap: [String: GenreMapping] = [
        "platform": .init(kind: .genre, value: "Platform"),
        "role playing game": .init(kind: .genre, value: "Role-playing (RPG)"),
        "role playing games": .init(kind: .genre, value: "Role-playing (RPG)"),
        "rpg": .init(kind: .genre, value: "Role-playing (RPG)"),
        "strategy": .init(kind: .genre, value: "Strategy"),
        "racing, driving": .init(kind: .genre, value: "Racing"),
        "racing": .init(kind: .genre, value: "Racing"),
        "driving": .init(kind: .genre, value: "Racing"),
        "adventure": .init(kind: .genre, value: "Adventure"),
        "puzzle": .init(kind: .genre, value: "Puzzle"),
        "puzzle-game": .init(kind: .genre, value: "Puzzle"),
        "shoot'em up": .init(kind: .genre, value: "Shooter"),
        "shoot’em up": .init(kind: .genre, value: "Shooter"),
        "shmup": .init(kind: .genre, value: "Shooter"),
        "shooter": .init(kind: .genre, value: "Shooter"),
        "lightgun shooter": .init(kind: .genre, value: "Shooter"),
        "run and gun": .init(kind: .genre, value: "Shooter"),
        "beat'em up": .init(kind: .genre, value: "Hack and slash/Beat 'em up"),
        "beat’em up": .init(kind: .genre, value: "Hack and slash/Beat 'em up"),
        "fighting": .init(kind: .genre, value: "Fighting"),
        "fight": .init(kind: .genre, value: "Fighting"),
        "sports": .init(kind: .genre, value: "Sport"),
        "sport": .init(kind: .genre, value: "Sport"),
        "sports with animals": .init(kind: .genre, value: "Sport"),
        "hunting and fishing": .init(kind: .genre, value: "Sport"),
        "board game": .init(kind: .genre, value: "Card & Board Game"),
        "asiatic board game": .init(kind: .genre, value: "Card & Board Game"),
        "playing cards": .init(kind: .genre, value: "Card & Board Game"),
        "casino": .init(kind: .genre, value: "Card & Board Game"),
        "simulation": .init(kind: .genre, value: "Simulator"),
        "pinball": .init(kind: .genre, value: "Pinball"),
        "quiz": .init(kind: .genre, value: "Quiz/Trivia"),
        "point-and-click": .init(kind: .genre, value: "Point-and-click"),
        "visual novel": .init(kind: .genre, value: "Visual Novel"),
        "compilation": .init(kind: .genre, value: "Arcade"),
        // Themes (IGDB models these as themes, not genres)
        "action": .init(kind: .theme, value: "Action"),
        "action / adventure": .init(kind: .theme, value: "Action"),
        "educational": .init(kind: .theme, value: "Educational"),
        "horror": .init(kind: .theme, value: "Horror"),
    ]

    /// The IGDB-style primary trait for a raw ScreenScraper genre string, or nil when the
    /// top-level segment is unknown (it still contributes keywords). Used for the dry-run
    /// coverage metric.
    static func primaryGenreTrait(for genre: String?) -> GameTrait? {
        guard let top = topSegment(of: genre) else { return nil }
        guard let m = genreMap[top] else { return nil }
        return GameTrait(kind: m.kind, value: m.value)
    }

    /// Whether a raw genre's top segment maps to a known genre/theme (not just keywords).
    static func mapsToKnownTrait(genre: String?) -> Bool {
        primaryGenreTrait(for: genre) != nil
    }

    /// Every taste trait for one catalogue entry's fields.
    static func traits(genre: String?, family: String?, developer: String?,
                       releaseYear: Int?) -> [GameTrait] {
        var out: [GameTrait] = []
        var seen = Set<GameTrait>()
        func add(_ t: GameTrait) { if seen.insert(t).inserted { out.append(t) } }

        // Genre → primary genre/theme + a keyword per segment.
        if let genre, !genre.trimmingCharacters(in: .whitespaces).isEmpty {
            if let primary = primaryGenreTrait(for: genre) { add(primary) }
            for seg in segments(of: genre) {
                let kw = seg.lowercased()
                if !kw.isEmpty { add(GameTrait(kind: .keyword, value: kw)) }
            }
        }
        if let family = clean(family) { add(GameTrait(kind: .franchise, value: family)) }
        if let dev = clean(developer) { add(GameTrait(kind: .developer, value: dev)) }
        if let releaseYear { add(GameTrait(kind: .decade, value: String((releaseYear / 10) * 10))) }
        return out
    }

    // MARK: - Helpers

    /// The lowercased top-level segment of a ScreenScraper genre (`"Shoot'em Up / Vertical"`
    /// → `"shoot'em up"`), or nil.
    static func topSegment(of genre: String?) -> String? {
        segments(of: genre).first?.lowercased()
    }

    /// All `/`-separated segments, trimmed and non-empty.
    static func segments(of genre: String?) -> [String] {
        guard let genre else { return [] }
        return genre.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
