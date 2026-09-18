import Foundation
import GRDB

/// Read side of ranking: `ValueObservation`s exposed as `AsyncSequence` (the
/// Tier Board / The Top / Duel views subscribe to these) plus `…Once` one-shots.
/// Every emitted value is a Foundation-only type from `VGN/Model/`.
extension RankingStore {

    // MARK: - Tier Board

    /// Live Tier Board rows (PLAN §7): per tier, its `TierInfo`, placed games in
    /// fine-rank order, and the dimmed unplaced tail. One query for the tiers, one
    /// for the games — no N+1.
    func tierBoard() -> AsyncValueObservation<[TierBoardRow]> {
        ValueObservation.tracking { db in try Self.fetchTierBoard(db) }.values(in: dbReader)
    }

    func tierBoardOnce() async throws -> [TierBoardRow] {
        try await dbReader.read { db in try Self.fetchTierBoard(db) }
    }

    static func fetchTierBoard(_ db: Database) throws -> [TierBoardRow] {
        let tiers = try TierRecord.order(sql: "sort, id").fetchAll(db).compactMap(\.info)
        let (sql, arguments) = LibraryQuery.tierBoardSQL()
        let summaries = try Row.fetchAll(db, sql: sql, arguments: arguments).map(LibraryQuery.gameSummary(from:))

        var placed: [Int64: [GameSummary]] = [:]
        var unplaced: [Int64: [GameSummary]] = [:]
        for summary in summaries {
            guard let tier = summary.tierID else { continue }
            if summary.rankKey != nil {
                placed[tier, default: []].append(summary)
            } else {
                unplaced[tier, default: []].append(summary)
            }
        }
        return tiers.map { TierBoardRow(tier: $0, placed: placed[$0.id] ?? [], unplaced: unplaced[$0.id] ?? []) }
    }

    // MARK: - The Top

    /// Live numbered chart (PLAN §7), **respecting the library filters** so
    /// "Top PS2 / Top 90s / Top RPGs" fall out for free. Placed games carry both
    /// their global position (over all placed games) and their derived position
    /// (within the filtered subset); unplaced games appear unnumbered at the end
    /// of their tier. Reuses `GlobalRank.filteredChart` over the loaded snapshot.
    func theTop(filter: LibraryFilter) -> AsyncValueObservation<[TopRow]> {
        ValueObservation.tracking { db in try Self.fetchTop(filter, db) }.values(in: dbReader)
    }

    func theTopOnce(filter: LibraryFilter) async throws -> [TopRow] {
        try await dbReader.read { db in try Self.fetchTop(filter, db) }
    }

    static func fetchTop(_ filter: LibraryFilter, _ db: Database) throws -> [TopRow] {
        let snapshot = try loadSnapshot(db)
        // The filter selects membership (platform / decade / genre / search / …);
        // ordering is imposed by the ranking, so `filter.sort` is ignored here.
        let summaries = try LibraryStore.fetchGames(filter, db)
        var summaryByID: [Int64: GameSummary] = [:]
        var subset: Set<Int64> = []
        for summary in summaries where summary.tierID != nil {
            summaryByID[summary.id] = summary
            subset.insert(summary.id)
        }

        var filteredByID: [Int64: GlobalRank.FilteredRow] = [:]
        for row in GlobalRank.filteredChart(snapshot, subset: subset) { filteredByID[row.id] = row }

        var rows: [TopRow] = []
        for slice in snapshot.orderedTiers {
            for item in slice.placed where subset.contains(item.id) {
                guard let summary = summaryByID[item.id], let fr = filteredByID[item.id] else { continue }
                rows.append(TopRow(game: summary,
                                   globalPosition: fr.globalPosition,
                                   derivedPosition: fr.derivedPosition))
            }
            for id in slice.unplaced where subset.contains(id) {
                guard let summary = summaryByID[id] else { continue }
                rows.append(TopRow(game: summary, globalPosition: nil, derivedPosition: nil))
            }
        }
        return rows
    }

    // MARK: - Duel queue count

    /// Games awaiting an initial placement (PLAN §8 "Duel" badge). Matches
    /// `SidebarCounts.duelQueue` exactly (played, tiered, no fine-rank key).
    func duelQueueCount() -> AsyncValueObservation<Int> {
        ValueObservation.tracking { db in try Self.fetchDuelQueueCount(db) }.values(in: dbReader)
    }

    func duelQueueCountOnce() async throws -> Int {
        try await dbReader.read { db in try Self.fetchDuelQueueCount(db) }
    }

    static func fetchDuelQueueCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM games
            WHERE played = 1 AND tier_id IS NOT NULL AND rank_key IS NULL
            """) ?? 0
    }

    // MARK: - Ranking stats

    /// Placed / unplaced counts per tier (PLAN §7). One grouped query.
    func rankingStats() -> AsyncValueObservation<RankingStats> {
        ValueObservation.tracking { db in try Self.fetchRankingStats(db) }.values(in: dbReader)
    }

    func rankingStatsOnce() async throws -> RankingStats {
        try await dbReader.read { db in try Self.fetchRankingStats(db) }
    }

    static func fetchRankingStats(_ db: Database) throws -> RankingStats {
        let tiers = try TierRecord.order(sql: "sort, id").fetchAll(db).compactMap(\.info)
        var counts: [Int64: (placed: Int, unplaced: Int)] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT tier_id,
                   SUM(rank_key IS NOT NULL) AS placed,
                   SUM(rank_key IS NULL)     AS unplaced
            FROM games WHERE played = 1 AND tier_id IS NOT NULL
            GROUP BY tier_id
            """) {
            let tier: Int64 = row["tier_id"]
            counts[tier] = (placed: row["placed"], unplaced: row["unplaced"])
        }
        let perTier = tiers.map { tier in
            RankingStats.TierStat(tierID: tier.id, letter: tier.letter,
                                  placed: counts[tier.id]?.placed ?? 0,
                                  unplaced: counts[tier.id]?.unplaced ?? 0)
        }
        return RankingStats(perTier: perTier)
    }
}
