import Foundation
import GRDB

// MARK: - Bundle expansion (PLAN §5.1 "Reconciling unlinked games" — the bundle rule)

/// Errors specific to expanding a placeholder game that is linked to (or matched with) an
/// IGDB bundle into a compilation of its member games.
enum BundleExpansionError: Error, Sendable, Equatable {
    case notFound
    /// The bundle had no member games to expand into (imperfect IGDB coverage) — the
    /// caller keeps the single game unchanged.
    case noMembers
    /// The placeholder game owns nothing and lists no platform, so there is nowhere to
    /// anchor the compilation copy.
    case noPlatform
}

/// The play data a placeholder game carries that must **not** be silently dropped when it
/// is expanded into a compilation (PLAN §5.1). When non-empty the confirm step offers a
/// member to move it onto; when empty the placeholder is simply deleted after re-pointing.
struct BundlePlaceholderData: Sendable, Equatable {
    var played: Bool
    var hasTier: Bool
    var hasRank: Bool
    var hasStatus: Bool
    var hasPlaytime: Bool
    var hasPlayDates: Bool
    var userEdited: Bool

    /// Nothing worth keeping → the placeholder can be deleted without asking.
    var isEmpty: Bool {
        !(played || hasTier || hasRank || hasStatus || hasPlaytime || hasPlayDates || userEdited)
    }

    init(_ g: GameRecord) {
        played = g.played
        hasTier = g.tierID != nil
        hasRank = g.rankKey != nil
        hasStatus = g.status != nil
        hasPlaytime = g.myPlaytimeS != nil || g.psnPlaytimeS != nil || g.batoceraPlaytimeS != nil
        hasPlayDates = g.firstPlayedAt != nil || g.lastPlayedAt != nil
        userEdited = !UserEditedFields(raw: g.userEdited).isEmpty
    }
}

/// What the confirm sheet needs before expanding a linked/matched placeholder game
/// (PLAN §5.1). `igdbID` nil ⇒ the game is unlinked and no bundle can be resolved.
struct BundleExpansionPreview: Sendable, Equatable {
    var gameID: Int64
    var title: String
    var igdbID: Int64?
    var platformIDs: [String]
    /// Whether the game sits alone in a `single` product (the repair-path candidate shape).
    var isLoneSingle: Bool
    var placeholder: BundlePlaceholderData
    /// True when the placeholder carries play data the expansion must move to a member.
    var carriesPlayData: Bool { !placeholder.isEmpty }
    /// The placeholder was played — the expand sheet asks per-member played ticks (D4c).
    var isPlayed: Bool { placeholder.played }
    /// The placeholder carries a tier/rank — the expand sheet shows the tier/rank target picker (D4c).
    var isRanked: Bool { placeholder.hasTier || placeholder.hasRank }
}

/// A library game that *looks* like an unexpanded bundle (PLAN §5.1 repair path). The
/// title heuristic is deliberately loose — the real check is an on-demand IGDB lookup when
/// the owner clicks, never a bulk verification on launch.
struct BundleExpansionCandidate: Sendable, Equatable, Identifiable {
    var gameID: Int64
    var title: String
    var igdbID: Int64?
    var id: Int64 { gameID }
}

/// An in-memory record of everything a bundle expansion touched, so it is reversible
/// through `UndoManager` (PLAN §5.1). Restores the pre-existing games verbatim and deletes
/// the member games that were created fresh.
struct BundleExpansionUndo: Sendable {
    var actionName: String
    /// Pre-existing games captured before the expansion (placeholder + any members already
    /// in the library + the play-data target when it was an existing member).
    var involvedGameIDs: [Int64]
    var snapshot: ReconcileSnapshot
    /// Member games created fresh during the expansion — deleted on undo.
    var createdGameIDs: [Int64]
}

/// The outcome of an expansion (PLAN §5.1).
struct BundleExpansionResult: Sendable {
    var productIDs: [Int64]
    var memberGameIDs: [Int64]
    var createdCount: Int
    var undo: BundleExpansionUndo
}

extension LibraryStore {

    /// A title heuristic for the repair-path candidate list (PLAN §5.1) — loose on purpose,
    /// verified against IGDB only on click. Case-insensitive, word-boundary-ish.
    ///
    /// Series-entry guard (W19 part 2B): a bundle keyword in the part *before* a colon,
    /// followed by a specific subtitle, is a **series entry** (one game), not a bundle —
    /// "The Dark Pictures Anthology: Man of Medan", "LEGO Harry Potter Collection: Years 1-4".
    /// The exception is a **volume marker** subtitle ("Volume I", "Vol. 2", a bare number), as
    /// in "8-bit Adventure Anthology: Volume I", which stays a bundle. A keyword only in the
    /// subtitle ("Halo: The Master Chief Collection") or with no colon is a bundle as before.
    static func looksLikeBundleTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        let words = ["trilogy", "collection", "anthology", "compilation", "pack",
                     "hd classics", "classics collection", "the orange box", "the master chief collection"]
        let hasKeyword = words.contains { lower.contains($0) }
        let hasNInOne = lower.range(of: #"\b\d+\s*[- ]?in[- ]?1\b"#, options: .regularExpression) != nil
        guard hasKeyword || hasNInOne else { return false }

        if hasKeyword, let colon = title.firstIndex(of: ":") {
            let before = title[..<colon].lowercased()
            let after = String(title[title.index(after: colon)...])
            // Keyword lives in the series NAME (before the colon) and a specific subtitle
            // follows → a series entry, unless that subtitle is a volume marker.
            if words.contains(where: { before.contains($0) }), !isVolumeMarker(after) {
                return false
            }
        }
        return true
    }

    /// A subtitle that marks a numbered volume of a set — "Volume I", "Vol. 2", a bare
    /// number or roman numeral. "Years 1-4" is *not* one (it is a range description).
    static func isVolumeMarker(_ subtitle: String) -> Bool {
        let s = subtitle.trimmingCharacters(in: .whitespaces).lowercased()
        if s.range(of: #"^(vol\.?|volume)\b"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil { return true }
        if s.range(of: #"^[ivxlcdm]+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Preview info for expanding one game (the inspector / reconcile confirm step).
    func bundleExpansionPreview(gameID: Int64) async throws -> BundleExpansionPreview {
        try await dbReader.read { db in
            guard let g = try GameRecord.fetchOne(db, key: gameID) else { throw BundleExpansionError.notFound }
            let platformIDs = try String.fetchAll(
                db, sql: "SELECT platform_id FROM game_platforms WHERE game_id = ? ORDER BY platform_id",
                arguments: [gameID])
            // Lone single: exactly one product, kind single, and this game its only member.
            let productIDs = try Int64.fetchAll(
                db, sql: "SELECT product_id FROM product_games WHERE game_id = ?", arguments: [gameID])
            var isLoneSingle = false
            if productIDs.count == 1, let pid = productIDs.first {
                let members = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM product_games WHERE product_id = ?", arguments: [pid]) ?? 0
                let kind = try String.fetchOne(db, sql: "SELECT kind FROM products WHERE id = ?", arguments: [pid])
                isLoneSingle = members == 1 && kind == "single"
            } else if productIDs.isEmpty {
                isLoneSingle = true    // played-only placeholder; nothing owned yet
            }
            return BundleExpansionPreview(
                gameID: gameID, title: g.title, igdbID: g.igdbID, platformIDs: platformIDs,
                isLoneSingle: isLoneSingle, placeholder: BundlePlaceholderData(g))
        }
    }

    /// `app_state` key holding the JSON array of game ids the owner dismissed as **"not a
    /// bundle"** from the Bundles-to-Expand list (PLAN §5.1) — persisted so a game that turned
    /// out not to be a bundle on IGDB never returns to the list.
    static let notBundleStateKey = "reconcile.notBundle"

    /// The dismissed-as-not-a-bundle game ids (persisted in `app_state`).
    func dismissedBundleCandidateIDs() async throws -> Set<Int64> {
        try await dbReader.read(Self.readDismissedBundleIDs)
    }

    static func readDismissedBundleIDs(_ db: Database) throws -> Set<Int64> {
        guard let json = try String.fetchOne(
                db, sql: "SELECT json FROM app_state WHERE key = ?", arguments: [notBundleStateKey]),
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else { return [] }
        return Set(ids)
    }

    /// Persist a "not a bundle" dismissal so the game leaves the Bundles-to-Expand list for good
    /// (PLAN §5.1). Idempotent.
    func dismissBundleCandidate(gameID: Int64) async throws {
        try await dbWriter.write { db in
            var ids = try Self.readDismissedBundleIDs(db)
            ids.insert(gameID)
            let json = (try? JSONEncoder().encode(ids.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            try db.execute(sql: """
                INSERT INTO app_state (key, json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET json = excluded.json, updated_at = excluded.updated_at
                """, arguments: [Self.notBundleStateKey, json, Date()])
        }
    }

    /// Library games whose title looks like an unexpanded bundle and that sit alone in a
    /// single product (or are linked, played-only) — repair-path candidates (PLAN §5.1).
    /// A loose heuristic; the real bundle check happens on click, per game. Games the owner
    /// dismissed as "not a bundle" are excluded.
    func bundleExpansionCandidates() async throws -> [BundleExpansionCandidate] {
        try await dbReader.read(Self.fetchBundleExpansionCandidates)
    }

    /// The one place the "Bundles to Expand" rule lives (PLAN §5.1 / §8): shared by the async
    /// API above, by the sidebar count (``GRDBLibraryDataSource/sidebarCounts(pace:style:)``)
    /// and by the smart-list grid scope (``LibraryStore/fetchGames(_:_:)`` for
    /// ``SidebarSelection/bundlesToExpand``). The title heuristic (``looksLikeBundleTitle``) is
    /// a Swift regex + keyword list that SQL can't express cheaply, so this fetches the
    /// candidate-shaped rows and applies the rule in Swift. It reads `games`, `product_games`
    /// and `app_state`, so a `ValueObservation` wrapping it re-runs on an expansion or a "not a
    /// bundle" dismissal — the count and the grid update themselves with no timer or callback.
    static func fetchBundleExpansionCandidates(_ db: Database) throws -> [BundleExpansionCandidate] {
        let dismissed = try readDismissedBundleIDs(db)
        // A game whose persisted import match (`import_titles.match_json`) says bundle/pack is a
        // candidate even when its title carries no hint (D4a — e.g. "Castlevania Requiem: Symphony
        // of the Night & Rondo of Blood"). The title heuristic still catches Trilogy/Collection/…
        let typedBundleGameIDs = try bundleTypedGameIDs(db)
        // W19 part 2B: for a LINKED game, its own cached IGDB payload (joined by igdb id, any
        // freshness — this is a classification hint, not displayed data) tells us the real
        // `game_type`. When we can read a *known* type it is authoritative: bundle/pack → in
        // even without a title hint; anything else → out even when the title matches the
        // heuristic. No cached payload / no type / an unrecognised type → fall back to today's
        // title-or-typed rule. Pure DB read, no request — one LEFT JOIN, `game_type` (or legacy
        // `category`) via json_extract on the candidate subset.
        let rows = try Row.fetchAll(db, sql: """
            SELECT g.id AS id, g.title AS title, g.igdb_id AS igdb_id,
                   (SELECT COUNT(*) FROM product_games pg WHERE pg.game_id = g.id) AS product_count,
                   (SELECT MAX(mc) FROM (
                        SELECT (SELECT COUNT(*) FROM product_games pg2 WHERE pg2.product_id = pg.product_id) AS mc
                        FROM product_games pg WHERE pg.game_id = g.id)) AS max_members,
                   COALESCE(json_extract(cc.json, '$.game_type'),
                            json_extract(cc.json, '$.category')) AS cached_type
            FROM games g
            LEFT JOIN catalog_cache cc ON cc.igdb_id = g.igdb_id
            ORDER BY g.sort_title
            """)
        return rows.compactMap { row in
            let gameID: Int64 = row["id"]
            guard !dismissed.contains(gameID) else { return nil }
            let title: String = row["title"]
            let titleOrTyped = looksLikeBundleTitle(title) || typedBundleGameIDs.contains(gameID)
            // Authoritative cached-type override (only when the type is one we recognise).
            let isCandidate: Bool
            if let raw: Int = row["cached_type"], case let type = IGDBGameType(rawValue: raw),
               Self.isRecognisedGameType(type) {
                isCandidate = type.isCompilation
            } else {
                isCandidate = titleOrTyped
            }
            guard isCandidate else { return nil }
            let productCount: Int = row["product_count"] ?? 0
            let maxMembers: Int = row["max_members"] ?? 0
            // Skip games that are already a compilation member (max_members > 1) — this also excludes
            // a bundle already expanded into a compilation, whose staging row's `matched_game_id`
            // (a member) would otherwise flag that member through `bundleTypedGameIDs`.
            guard productCount == 0 || maxMembers <= 1 else { return nil }
            return BundleExpansionCandidate(gameID: row["id"], title: title, igdbID: row["igdb_id"])
        }
    }

    /// Whether `type` is a `game_type` value VGN recognises (not `.unknown`) — only then is a
    /// cached type authoritative for the candidate rule (W19 part 2B).
    static func isRecognisedGameType(_ type: IGDBGameType) -> Bool {
        if case .unknown = type { return false }
        return true
    }

    /// Game ids whose persisted import match (`import_titles.match_json`) resolved to an IGDB
    /// **bundle/pack** (D4a). SQL can't parse the JSON blob, so this reads the matched rows and
    /// checks the decoded outcome's `game_type` in Swift. Shared by ``fetchBundleExpansionCandidates``.
    static func bundleTypedGameIDs(_ db: Database) throws -> Set<Int64> {
        var ids = Set<Int64>()
        for row in try Row.fetchAll(db, sql: """
            SELECT matched_game_id AS gid, match_json AS mj FROM import_titles
            WHERE matched_game_id IS NOT NULL AND match_json IS NOT NULL
            """) {
            guard let gid: Int64 = row["gid"], let mj: String = row["mj"],
                  let match = ImportStagingStore.decodeMatch(mj),
                  match.outcome.best?.gameType?.isCompilation == true else { continue }
            ids.insert(gid)
        }
        return ids
    }

    /// The candidate game ids only (PLAN §5.1) — the id set the grid scope filters by.
    static func fetchBundleExpansionCandidateIDs(_ db: Database) throws -> [Int64] {
        try fetchBundleExpansionCandidates(db).map(\.gameID)
    }

    /// Bundle-expansion candidates that carry **no play data** (D4b — the "Expand All Unplayed"
    /// batch): a candidate whose game has no played flag, tier, rank, status, playtime, dates or
    /// hand-edit (``BundlePlaceholderData/isEmpty``). Played candidates are expanded one at a time
    /// through the per-game sheet (D4c). Ordered like ``bundleExpansionCandidates``.
    func unplayedBundleExpansionCandidates() async throws -> [BundleExpansionCandidate] {
        try await dbReader.read { db in
            try Self.fetchBundleExpansionCandidates(db).filter { candidate in
                guard let g = try GameRecord.fetchOne(db, key: candidate.gameID) else { return false }
                return BundlePlaceholderData(g).isEmpty
            }
        }
    }

    /// Expand a placeholder game into a compilation of `members` in one transaction
    /// (PLAN §5.1). Each of the game's product(s) becomes a `compilation` titled
    /// `bundleTitle`; the members are upserted/deduped (a member already in the library is
    /// linked, never duplicated) and attached; the placeholder is removed from those
    /// products. When it carries no play data it is deleted; when it does, its
    /// played/status/tier/rank/playtime/dates are moved to `playDataTargetIndex`'s member
    /// (default the first) before it is deleted — respecting *only played games carry a
    /// tier/rank* and rank-order consistency (the placeholder is deleted, freeing its
    /// rank_key). Returns an undo record.
    @discardableResult
    func expandBundle(gameID: Int64, bundleTitle: String,
                      members: [CompilationMemberDraft],
                      playDataTargetIndex: Int? = 0) async throws -> BundleExpansionResult {
        guard !members.isEmpty else { throw BundleExpansionError.noMembers }
        return try await dbWriter.write { db in
            guard let g = try GameRecord.fetchOne(db, key: gameID) else { throw BundleExpansionError.notFound }
            let placeholder = BundlePlaceholderData(g)

            // Existing library games among the members (for the undo snapshot) — before mutation.
            var existingMemberIDs: [Int64] = []
            for member in members {
                guard let igdbID = member.igdbID,
                      let id = try Int64.fetchOne(
                        db, sql: "SELECT id FROM games WHERE igdb_id = ?", arguments: [igdbID]) else { continue }
                if !existingMemberIDs.contains(id) { existingMemberIDs.append(id) }
            }
            var involved = [gameID]
            for id in existingMemberIDs where !involved.contains(id) { involved.append(id) }
            let snapshot = try Self.captureSnapshot(involved, db)

            // The products to convert. If the placeholder owns nothing, anchor one new
            // compilation product on its first platform.
            var productIDs = try Int64.fetchAll(
                db, sql: "SELECT product_id FROM product_games WHERE game_id = ? ORDER BY product_id",
                arguments: [gameID])
            let platforms = try String.fetchAll(
                db, sql: "SELECT platform_id FROM game_platforms WHERE game_id = ? ORDER BY platform_id",
                arguments: [gameID])
            if productIDs.isEmpty {
                guard let platform = platforms.first else { throw BundleExpansionError.noPlatform }
                let now = Date()
                try db.execute(sql: """
                    INSERT INTO products (title, platform_id, kind, format, source, created_at, updated_at)
                    VALUES (?, ?, 'compilation', ?, ?, ?, ?)
                    """, arguments: [bundleTitle, platform, ProductFormat.physical.rawValue,
                                     ProductSource.manual.rawValue, now, now])
                productIDs = [db.lastInsertedRowID]
            }

            // Members of a bundle-derived compilation order by first release date (§5.1).
            // Array order is preserved (only `position` changes), so the index mapping and
            // `playDataTargetIndex` below stay valid.
            let orderedMembers = Self.orderedByReleaseDate(members)

            // Convert each product and attach every member; map member index → game id
            // (stable across products because upsert dedupes by igdb id).
            var memberGameIDByIndex: [Int: Int64] = [:]
            var createdGameIDs: [Int64] = []
            var allMemberGameIDs: [Int64] = []
            for pid in productIDs {
                guard let prow = try Row.fetchOne(
                    db, sql: "SELECT platform_id, source FROM products WHERE id = ?", arguments: [pid])
                else { continue }
                let productPlatform: String = prow["platform_id"]
                let productSource = ProductSource(rawValue: prow["source"]) ?? .manual
                try db.execute(sql: "UPDATE products SET kind = 'compilation', title = ?, updated_at = ? WHERE id = ?",
                               arguments: [bundleTitle, Date(), pid])
                for (index, member) in orderedMembers.enumerated() {
                    let outcome = try Self.upsertCompilationMember(
                        member, productID: pid, platformID: productPlatform, source: productSource, db: db)
                    if memberGameIDByIndex[index] == nil { memberGameIDByIndex[index] = outcome.gameID }
                    if case .created = outcome, !createdGameIDs.contains(outcome.gameID) {
                        createdGameIDs.append(outcome.gameID)
                    }
                    if !allMemberGameIDs.contains(outcome.gameID) { allMemberGameIDs.append(outcome.gameID) }
                }
                // The placeholder is no longer a member of this product.
                try db.execute(sql: "DELETE FROM product_games WHERE product_id = ? AND game_id = ?",
                               arguments: [pid, gameID])
            }

            // Move the placeholder's play data onto the chosen member, then delete it.
            if !placeholder.isEmpty {
                let index = playDataTargetIndex ?? 0
                if let targetID = memberGameIDByIndex[index] ?? memberGameIDByIndex[0] {
                    try Self.transferPlayData(from: g, to: targetID, db: db)
                }
            }
            try Self.deleteGameRow(gameID, db)

            let undo = BundleExpansionUndo(
                actionName: "Expand Bundle", involvedGameIDs: involved,
                snapshot: snapshot, createdGameIDs: createdGameIDs)
            return BundleExpansionResult(
                productIDs: productIDs, memberGameIDs: allMemberGameIDs,
                createdCount: createdGameIDs.count, undo: undo)
        }
    }

    /// Undo a bundle expansion: delete the freshly-created member games, then restore the
    /// pre-existing games (placeholder + existing members) verbatim (PLAN §5.1).
    func restoreBundleExpansion(_ undo: BundleExpansionUndo) async throws {
        try await dbWriter.write { db in
            for id in undo.createdGameIDs {
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)",
                                     arguments: [id]) ?? false {
                    try Self.deleteGameRow(id, db)
                }
            }
            try Self.applySnapshot(undo.snapshot, gameIDs: undo.involvedGameIDs, db)
        }
    }

    /// Move the placeholder's played state / status / tier / rank / playtime / dates onto a
    /// member (PLAN §5.1). Merge rules mirror ``performMerge``: the member keeps its own
    /// scalar when set, otherwise adopts the placeholder's; the tier/rank carries only when
    /// the member is unranked (the placeholder is deleted right after, freeing its
    /// `rank_key`, so uniqueness holds). Invariant 2 ("only played games carry a tier/rank")
    /// is preserved because a tiered placeholder is always played, so `played` is OR-ed on.
    private static func transferPlayData(from source: GameRecord, to targetID: Int64, db: Database) throws {
        guard var target = try GameRecord.fetchOne(db, key: targetID) else { return }
        target.played = target.played || source.played
        target.status = target.status ?? source.status
        target.myPlaytimeS = target.myPlaytimeS ?? source.myPlaytimeS
        target.psnPlaytimeS = target.psnPlaytimeS ?? source.psnPlaytimeS
        target.batoceraPlaytimeS = [target.batoceraPlaytimeS, source.batoceraPlaytimeS].compactMap { $0 }.max()
        if target.tierID == nil, let tier = source.tierID {
            target.tierID = tier                  // played already 1 above (invariant 2 holds)
            target.rankKey = source.rankKey
        }
        target.updatedAt = Date()
        try target.update(db)
        // Earliest / latest known play date (monotonic; nil never overwrites).
        try setPSNPlayedDates(gameID: targetID, first: source.firstPlayedAt, last: source.lastPlayedAt, db: db)
        // Reflect the played flag on the member's platform rows.
        if target.played {
            for platform in try String.fetchAll(
                db, sql: "SELECT platform_id FROM game_platforms WHERE game_id = ?", arguments: [targetID]) {
                try ensureGamePlatform(gameID: targetID, platformID: platform, played: true, db: db)
            }
        }
    }
}
