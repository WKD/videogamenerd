import Foundation

/// Pure duplicate folding for a Batocera system's entries (PLAN §15). The owner's set is
/// 1G1R, so this is a **safety net**, not the main mechanism: it collapses multi-disc files
/// (`(Disc 1)`, `(Disc 2)`…), revisions, hacks/translations and the odd leftover regional
/// twin that share one game. Foundation only — it reuses the `LibretroFilenameParser` /
/// libretro key already used by the cover matcher, so the fold key is identical to the one
/// the rest of VGN normalises to.
enum BatoceraFolding {

    /// Preferred region order when neither twin has play data (PLAN §15 — EU > US > JP).
    /// Values are the lowercased Batocera `<region>` codes.
    static let regionPreference: [String] = ["eu", "us", "wr", "jp", "kr", "cn", "br", "in"]

    /// One folded title: the kept representative plus the entries that folded into it.
    struct Group: Sendable, Hashable {
        var representative: BatoceraGame
        var libretroKey: String
        /// Total entries in the group (1 ⇒ nothing folded).
        var memberCount: Int
        /// Relative paths that folded away (the non-representatives), for reporting.
        var foldedAwayPaths: [String]
    }

    struct Result: Sendable {
        var groups: [Group]
        /// How many entries were folded away (input count − group count).
        var foldedCount: Int
    }

    /// The fold key for one game: the libretro key of its **file name** (region / disc /
    /// revision tags stripped, punctuation folded, articles dropped). The file name is used
    /// rather than `<name>` because `<name>` is often only the subtitle, while the file name
    /// carries the full No-Intro title.
    static func foldKey(for game: BatoceraGame) -> String {
        let stem = (game.fileName as NSString).deletingPathExtension
        let parsed = LibretroFilenameParser.parse(stem)
        let key = LibretroIndex.libretroKey(parsed.title)
        // A game whose title normalises to nothing (rare) keys on its own path so it is
        // never merged with an unrelated empty-key entry.
        return key.isEmpty ? "\u{0}\(game.relativePath)" : key
    }

    /// Fold a system's entries. Order of the returned groups follows first appearance so the
    /// result is deterministic.
    static func fold(_ games: [BatoceraGame]) -> Result {
        var order: [String] = []
        var buckets: [String: [BatoceraGame]] = [:]
        for game in games {
            let key = foldKey(for: game)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(game)
        }

        var groups: [Group] = []
        groups.reserveCapacity(order.count)
        for key in order {
            let members = buckets[key] ?? []
            let rep = chooseRepresentative(members)
            let foldedAway = members.filter { $0.relativePath != rep.relativePath }.map(\.relativePath)
            groups.append(Group(representative: rep, libretroKey: key,
                                memberCount: members.count, foldedAwayPaths: foldedAway))
        }
        return Result(groups: groups, foldedCount: games.count - groups.count)
    }

    /// Pick the entry to keep: the one with play data first (most game time, then a
    /// favourite), then the preferred region, then Disc 1, then the lexicographically first
    /// path for stability.
    static func chooseRepresentative(_ members: [BatoceraGame]) -> BatoceraGame {
        members.min { a, b in selectionKey(a) < selectionKey(b) } ?? members[0]
    }

    private struct SelectionKey: Comparable {
        var noPlayData: Int      // 0 = has play data (preferred)
        var negGameTime: Int     // more game time preferred
        var notFavorite: Int     // 0 = favourite preferred
        var region: Int          // lower = preferred region
        var disc: Int            // Disc 1 preferred
        var path: String
        static func < (l: SelectionKey, r: SelectionKey) -> Bool {
            if l.noPlayData != r.noPlayData { return l.noPlayData < r.noPlayData }
            if l.negGameTime != r.negGameTime { return l.negGameTime < r.negGameTime }
            if l.notFavorite != r.notFavorite { return l.notFavorite < r.notFavorite }
            if l.region != r.region { return l.region < r.region }
            if l.disc != r.disc { return l.disc < r.disc }
            return l.path < r.path
        }
    }

    private static func selectionKey(_ g: BatoceraGame) -> SelectionKey {
        let hasPlay = g.gameTimeSeconds > 0 || g.playCount > 0
        let regionRank = regionPreference.firstIndex(of: (g.region ?? "").lowercased()) ?? Int.max
        let stem = (g.fileName as NSString).deletingPathExtension
        let disc = LibretroFilenameParser.parse(stem).disc ?? 1
        return SelectionKey(
            noPlayData: hasPlay ? 0 : 1,
            negGameTime: -g.gameTimeSeconds,
            notFavorite: g.isFavorite ? 0 : 1,
            region: regionRank,
            disc: disc == 1 ? 0 : disc,
            path: g.relativePath)
    }
}
