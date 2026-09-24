import Foundation
import GRDB

/// SQL → engine-input loading for ``RecommendationStore``. Kept apart from the
/// public surface for readability. All queries are single scans with `IN (…)`
/// filters — no N+1.
extension RecommendationStore {

    // MARK: - Full input

    static func loadInput(
        bracket: TimeBracket, options: RecommendationOptions,
        weights: RecommendationWeights, db: Database
    ) throws -> RecommendationInput {
        let ranked = try loadRankedGames(db: db)
        let candidates = try loadCandidates(db: db)
        let feedback = try loadFeedback(weights: weights, db: db)
        return RecommendationInput(ranked: ranked, candidates: candidates, bracket: bracket,
                                   feedback: feedback, options: options, weights: weights)
    }

    // MARK: - Ranked games (taste profile)

    /// Every tiered game as a ``RankedGame`` with its rank-derived score and full
    /// feature set (persisted traits + synthesised genre / platform / decade).
    static func loadRankedGames(db: Database) throws -> [RankedGame] {
        let snapshot = try RankingStore.loadSnapshot(db)
        let scores = TasteScoring.rankScores(snapshot: snapshot)
        guard !scores.isEmpty else { return [] }

        let ids = Array(scores.keys)
        let igdbByID = try igdbIDs(for: ids, db: db)
        let features = try loadFeatures(ids: ids, db: db)
        let firstYears = try firstPlayedYears(for: ids, db: db)

        return ids.map { id in
            RankedGame(id: id, igdbID: igdbByID[id] ?? nil, score: scores[id] ?? 0.5,
                       traits: features[id]?.traits ?? [], firstPlayedYear: firstYears[id])
        }
    }

    // MARK: - Candidates

    /// Owned games (any format, incl. compilation members and ROM copies) whose
    /// status is not finished/completed — the backlog + playing + abandoned +
    /// played-without-status. Status/estimate/ownership come together; the engine
    /// applies the opt-in filters.
    static func loadCandidates(db: Database) throws -> [Candidate] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT g.id, g.igdb_id, g.title, g.year, g.played, g.status, g.revisit,
                   g.holds_up, g.first_played_at,
                   \(LibraryQuery.effectivePlaytimeSQL()) AS effective_playtime_s,
                   g.ttb_hastily_s, g.ttb_normally_s, g.ttb_completely_s,
                   g.ttb_source,
                   g.igdb_rating, g.igdb_rating_count, g.cover_file,
                   NOT EXISTS (
                       SELECT 1 FROM product_games pgx JOIN products px ON px.id = pgx.product_id
                       WHERE pgx.game_id = g.id AND px.subscription IS NULL
                   ) AS sub_only,
                   EXISTS (
                       SELECT 1 FROM rom_catalog rc
                       WHERE rc.promoted_game_id = g.id AND rc.favorite = 1 AND rc.removed_at IS NULL
                   ) AS bato_fav
            FROM games g
            WHERE EXISTS (SELECT 1 FROM product_games pg WHERE pg.game_id = g.id)
              AND (g.status IS NULL OR g.status NOT IN ('finished','completed'))
            """)
        guard !rows.isEmpty else { return [] }

        let ids = rows.map { $0["id"] as Int64 }
        let features = try loadFeatures(ids: ids, db: db)
        let formats = try loadFormats(ids: ids, db: db)
        // A flagged completionist is ignored for the length input (PLAN §5.3, D5): the
        // engine's time fit sees the same fallback the BY LENGTH shelves use.
        let dismissedEstimates = try LibraryStore.readDismissedEstimateIDs(db)

        return rows.compactMap { row -> Candidate? in
            let id: Int64 = row["id"]
            let played: Bool = row["played"]
            let statusRaw: String? = row["status"]
            let revisit = (row["revisit"] as Int64?) == 1
            guard let status = recStatus(played: played, statusRaw: statusRaw, revisit: revisit) else { return nil }
            let igdbID: Int64? = row["igdb_id"]
            let feature = features[id]
            let length = EstimateSanity.lengthInputs(
                rushed: row["ttb_hastily_s"], main: row["ttb_normally_s"],
                completionist: row["ttb_completely_s"],
                sourceIsHLTB: (row["ttb_source"] as String?) == HLTBSource.id,
                dismissed: dismissedEstimates.contains(id))
            return Candidate(
                id: id,
                igdbID: igdbID,
                traits: feature?.traits ?? [],
                estimateSeconds: length.main,
                completionistSeconds: length.completionist,
                // Effective play time (manual, else max(PSN, Batocera) — v17), so Play Next's
                // remaining time for Playing / To Revisit counts imported hours too.
                myPlaytimeSeconds: row["effective_playtime_s"],
                status: status,
                igdbRating: row["igdb_rating"],
                ratingCount: row["igdb_rating_count"],
                hasMetadata: igdbID != nil,
                title: row["title"],
                year: row["year"],
                coverFile: row["cover_file"],
                platformIDs: feature?.platformSlugs ?? [],
                formats: formats[id] ?? [],
                playStatus: PlayStatus.from(dbStatus: statusRaw, revisit: revisit),
                ownedOnlyViaSubscription: row["sub_only"],
                isBatoceraFavourite: row["bato_fav"],
                // "Holds up today?" (PLAN §7b) — adjusts this candidate only (never the profile).
                holdsUp: HoldsUp(dbValue: row["holds_up"]),
                firstPlayedAt: row["first_played_at"]
            )
        }
    }

    /// Map the stored `(status, revisit)` pair to the engine's candidate status. A
    /// `'abandoned' AND revisit=1` game is **To Revisit** — a candidate by default (no
    /// opt-in), unlike plain Abandoned.
    static func recStatus(played: Bool, statusRaw: String?, revisit: Bool) -> RecCandidateStatus? {
        switch statusRaw {
        case "playing": return .playing
        case "abandoned": return revisit ? .toRevisit : .abandoned
        case "finished", "completed": return nil          // never a candidate
        case nil: return played ? .playedUnknown : .backlog
        default: return played ? .playedUnknown : .backlog
        }
    }

    // MARK: - Features (traits + genre + platform + decade)

    struct GameFeatures {
        var traits: [GameTrait]
        var platformSlugs: [String]
    }

    /// Load the full engine feature set for a set of game ids: persisted
    /// `game_traits` plus synthesised `genre` (from `game_genres`), `platform`
    /// (owned + played-on platforms) and `decade` (from `year`) features.
    static func loadFeatures(ids: [Int64], db: Database) throws -> [Int64: GameFeatures] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let args = StatementArguments(ids)

        var persisted: [Int64: [GameTrait]] = [:]
        for row in try Row.fetchAll(db, sql:
            "SELECT game_id, kind, value FROM game_traits WHERE game_id IN (\(placeholders))", arguments: args) {
            let gid: Int64 = row["game_id"]
            if let kind = GameTraitKind(rawValue: row["kind"]) {
                persisted[gid, default: []].append(GameTrait(kind: kind, value: row["value"]))
            }
        }

        var genres: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT gg.game_id AS gid, ge.name AS name FROM game_genres gg
            JOIN genres ge ON ge.id = gg.genre_id WHERE gg.game_id IN (\(placeholders))
            """, arguments: args) {
            genres[row["gid"], default: []].append(row["name"])
        }

        var platforms: [Int64: [String]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT gid, pid FROM (
              SELECT game_id AS gid, platform_id AS pid FROM game_platforms WHERE game_id IN (\(placeholders))
              UNION
              SELECT pg.game_id, p.platform_id FROM product_games pg
                JOIN products p ON p.id = pg.product_id WHERE pg.game_id IN (\(placeholders))
            )
            """, arguments: StatementArguments(ids + ids)) {
            platforms[row["gid"], default: []].append(row["pid"])
        }

        var years: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql:
            "SELECT id, year FROM games WHERE id IN (\(placeholders)) AND year IS NOT NULL", arguments: args) {
            years[row["id"]] = row["year"]
        }

        var out: [Int64: GameFeatures] = [:]
        for id in ids {
            var traits = persisted[id] ?? []
            for genre in genres[id] ?? [] { traits.append(GameTrait(kind: .genre, value: genre)) }
            let slugs = platforms[id] ?? []
            for slug in slugs { traits.append(GameTrait(kind: .platform, value: slug)) }
            if let year = years[id] {
                traits.append(GameTrait(kind: .decade, value: String((year / 10) * 10)))
            }
            out[id] = GameFeatures(traits: traits, platformSlugs: slugs)
        }
        return out
    }

    /// Owned formats per game (for the display line).
    static func loadFormats(ids: [Int64], db: Database) throws -> [Int64: [ProductFormat]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var out: [Int64: Set<ProductFormat>] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT pg.game_id AS gid, p.format AS format FROM product_games pg
            JOIN products p ON p.id = pg.product_id WHERE pg.game_id IN (\(placeholders))
            """, arguments: StatementArguments(ids)) {
            if let format = ProductFormat(rawValue: row["format"]) {
                out[row["gid"], default: []].insert(format)
            }
        }
        // Stable, catalogue order.
        return out.mapValues { set in ProductFormat.allCases.filter(set.contains) }
    }

    /// The importer-filled first-played **year** (v9) per game, for the backtest's optional
    /// "exclude games first played before …" cutoff (PLAN §7b). Games without one are absent.
    static func firstPlayedYears(for ids: [Int64], db: Database) throws -> [Int64: Int] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var out: [Int64: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, CAST(strftime('%Y', first_played_at) AS INTEGER) AS y
            FROM games WHERE id IN (\(placeholders)) AND first_played_at IS NOT NULL
            """, arguments: StatementArguments(ids)) {
            if let year = row["y"] as Int? { out[row["id"]] = year }
        }
        return out
    }

    static func igdbIDs(for ids: [Int64], db: Database) throws -> [Int64: Int64?] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var out: [Int64: Int64?] = [:]
        for row in try Row.fetchAll(db, sql:
            "SELECT id, igdb_id FROM games WHERE id IN (\(placeholders))", arguments: StatementArguments(ids)) {
            out[row["id"]] = row["igdb_id"] as Int64?
        }
        return out
    }

    // MARK: - Feedback

    static func loadFeedback(weights: RecommendationWeights, db: Database) throws -> RecFeedbackState {
        var never: Set<Int64> = []
        var snoozedUntil: [Int64: Double] = [:]
        var picked: Set<Int64> = []
        // Rotation memory only counts recent picks, so the pitch keeps moving.
        let pickedWindow: TimeInterval = 90 * 24 * 3600
        let nowSeconds = Date().timeIntervalSince1970

        for row in try Row.fetchAll(db, sql: """
            SELECT game_id, action, MAX(created_at) AS last FROM rec_feedback
            GROUP BY game_id, action
            """) {
            let gid: Int64 = row["game_id"]
            let action: String = row["action"]
            let last: Date = row["last"]
            switch action {
            case "never":
                never.insert(gid)
            case "snooze":
                snoozedUntil[gid] = last.timeIntervalSince1970 + weights.snoozeWindow
            case "picked":
                if nowSeconds - last.timeIntervalSince1970 <= pickedWindow { picked.insert(gid) }
            default:
                break
            }
        }
        return RecFeedbackState(snoozedUntil: snoozedUntil, never: never, picked: picked)
    }

    // MARK: - Second opinion

    static func buildSecondOpinion(
        result: PlayNextResult, topRankedLimit: Int, db: Database
    ) throws -> SecondOpinionRequest {
        let taste = try secondOpinionTaste(topRankedLimit: topRankedLimit, db: db)

        // Shortlist (hero + alternatives) in engine order.
        let shortlist = result.shortlist.enumerated().map { index, s in
            SecondOpinionRequest.Shortlisted(
                id: s.id, title: s.title,
                platform: s.platformIDs.first,
                format: s.formats.first?.rawValue,
                estimateHours: s.estimateSeconds.map { (Double($0) / 3600).rounded(toPlaces: 1) },
                status: s.status?.rawValue,
                engineRank: index + 1)
        }

        return SecondOpinionRequest(
            bracket: result.bracket.label,
            completionist: result.bracket.completionist,
            topRanked: taste.topRanked,
            didntClick: taste.didntClick,
            shortlist: shortlist,
            engineOrdering: result.shortlist.map(\.id))
    }

    /// The tier list (top ~60 by global rank) + the D–F "didn't click" titles — the taste half
    /// every "Ask Claude" prompt carries (regular picks and "From the vault").
    static func secondOpinionTaste(topRankedLimit: Int, db: Database) throws -> SecondOpinionTaste {
        let snapshot = try RankingStore.loadSnapshot(db)

        // tier id → letter, and titles for the ids we cite.
        var tierLetter: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, letter FROM tiers") {
            tierLetter[row["id"]] = row["letter"]
        }

        // Top ranked (~60), in global tier order: placed (by key) then the unplaced
        // tail per tier, so a not-yet-dueled tier list is still represented.
        var orderedIDs: [(id: GameID, tier: TierID)] = []
        for slice in snapshot.orderedTiers {
            for item in slice.placed { orderedIDs.append((item.id, slice.tier)) }
            for id in slice.unplaced { orderedIDs.append((id, slice.tier)) }
        }
        let topRows = Array(orderedIDs.prefix(topRankedLimit))
        let topTitles = try titles(for: topRows.map(\.id), db: db)
        let topRanked = topRows.enumerated().map { index, row in
            SecondOpinionRequest.RankedTitle(
                title: topTitles[row.id] ?? "",
                tier: tierLetter[row.tier] ?? "",
                globalPosition: index + 1)
        }

        // D–F "didn't click".
        var didntClick: [SecondOpinionRequest.DislikedTitle] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT g.title AS title, t.letter AS letter FROM games g
            JOIN tiers t ON t.id = g.tier_id
            WHERE g.played = 1 AND t.letter IN ('D','F')
            ORDER BY t.sort, g.rank_key
            """) {
            didntClick.append(.init(title: row["title"], tier: row["letter"]))
        }
        return SecondOpinionTaste(topRanked: topRanked, didntClick: didntClick)
    }

    static func titles(for ids: [Int64], db: Database) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(db, sql:
            "SELECT id, title FROM games WHERE id IN (\(placeholders))", arguments: StatementArguments(ids)) {
            out[row["id"]] = row["title"]
        }
        return out
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
