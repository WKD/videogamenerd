#if DEBUG
import CoreGraphics
import Foundation

/// A hand-driven ``RankingBackend`` for SwiftUI previews **and** the model unit
/// tests. Every output is a settable property and every call is recorded, so a
/// test can script "answer → next prompt", "prompt disappears mid-flight",
/// border accept/dismiss, drained empty state, etc. — with no database.
///
/// `@unchecked Sendable`: it is only ever touched from a single actor (the
/// `@MainActor` model / test), which the `RankingBackend: Sendable` requirement
/// formally needs but this fake does not synchronise.
final class ScriptedRankingBackend: RankingBackend, @unchecked Sendable {
    // Scripted outputs
    var currentPrompt: DuelPrompt?
    var nextOutcome: DuelOutcome = .none
    var undoResult = true
    var details: [Int64: GameDetail] = [:]
    var tierList: [TierInfo] = TierInfo.defaults
    var board: [TierBoardRow] = []
    var topRows: [TopRow] = []
    var unranked: [GameSummary] = []
    var queueCount = 0
    var stats = RankingStats(perTier: [])
    var disputes: [Consistency.Dispute] = []
    var setTierResult: SetTierOutcome?
    /// Scripted outcome for `markNotPlayed` (Triage `U`).
    var unplayOutcome: UnplayOutcome = .becameBacklog
    private(set) var unplayed: [Int64] = []
    private(set) var deleted: [Int64] = []
    /// When true, `move` / `clearTier` mutate `board` in place (so a model's
    /// `tierBoardOnce()` reconcile sees the effect) using the same insertion
    /// semantics as `RankMoves`. Off by default so index-math tests inspect the
    /// recorded calls without the board shifting underneath them.
    var autoApplyMoves = false

    // Recorded calls
    private(set) var answered: [Int64] = []
    private(set) var skipCount = 0
    private(set) var undoCount = 0
    private(set) var accepted: [BorderSuggestion] = []
    private(set) var dismissed: [BorderSuggestion] = []
    private(set) var rePlaced: [Int64] = []
    private(set) var tierCalls: [(ids: [Int64], tierID: Int64?)] = []
    private(set) var moves: [(gameID: Int64, toTier: Int64, atIndex: Int?)] = []
    private(set) var clearedTiers: [Int64] = []
    private(set) var dividerMoves: [(upper: Int64, lower: Int64, k: Int)] = []
    /// Scores returned by `derivedScores()`; settable for previews / tests.
    var scores: [Int64: DerivedScoreValue] = [:]
    var dividerOutcome = DividerMoveOutcome(movedIDs: [], upperPlaced: 0, lowerPlaced: 0)

    // MARK: Duel flow
    func currentDuel() async throws -> DuelPrompt? { currentPrompt }

    func answer(winner: Int64) async throws -> DuelOutcome {
        answered.append(winner)
        return nextOutcome
    }

    func skip() async throws { skipCount += 1 }
    func undo() async throws -> Bool { undoCount += 1; return undoResult }
    func acceptBorderSuggestion(_ s: BorderSuggestion) async throws { accepted.append(s) }
    func dismissBorderSuggestion(_ s: BorderSuggestion) async throws { dismissed.append(s) }
    func rePlace(_ gameID: Int64) async throws { rePlaced.append(gameID) }

    // MARK: Tiering
    func setTier(_ ids: [Int64], tierID: Int64?) async throws -> SetTierOutcome {
        tierCalls.append((ids, tierID))
        return setTierResult ?? SetTierOutcome(applied: ids, skippedUnplayed: [])
    }

    // MARK: Triage-safe un-play
    func markNotPlayed(_ gameID: Int64) async throws -> UnplayOutcome {
        unplayed.append(gameID)
        return unplayOutcome
    }
    func deleteGame(_ gameID: Int64) async throws { deleted.append(gameID) }

    // MARK: Drag / drop overrides
    func move(gameID: Int64, toTier: Int64, atIndex: Int?) async throws {
        moves.append((gameID, toTier, atIndex))
        if autoApplyMoves { board = Self.applyMove(board, gameID: gameID, toTier: toTier, atIndex: atIndex) }
    }
    func clearTier(_ gameID: Int64) async throws {
        clearedTiers.append(gameID)
        if autoApplyMoves { board = Self.removeGame(board, gameID) }
    }
    func moveDivider(between upperTierID: Int64, and lowerTierID: Int64, by k: Int) async throws -> DividerMoveOutcome {
        dividerMoves.append((upperTierID, lowerTierID, k))
        return dividerOutcome
    }

    // MARK: Reads
    func gameDetail(id: Int64) async throws -> GameDetail? { details[id] }
    func tiers() async throws -> [TierInfo] { tierList }
    func tierBoardOnce() async throws -> [TierBoardRow] { board }
    func theTopOnce(filter: LibraryFilter) async throws -> [TopRow] { topRows }
    func derivedScores() async throws -> [Int64: DerivedScoreValue] { scores }
    func unrankedPlayedGames() async throws -> [GameSummary] { unranked }
    func duelQueueCountOnce() async throws -> Int { queueCount }
    func rankingStatsOnce() async throws -> RankingStats { stats }
    func contradictions() async throws -> [Consistency.Dispute] { disputes }

    // MARK: Streams (single value then finish, so subscribers don't hang)
    func duelQueueCountStream() -> AsyncStream<Int> {
        let v = queueCount; return AsyncStream { $0.yield(v); $0.finish() }
    }
    func rankingStatsStream() -> AsyncStream<RankingStats> {
        let v = stats; return AsyncStream { $0.yield(v); $0.finish() }
    }
    func unrankedGamesStream() -> AsyncStream<[GameSummary]> {
        let v = unranked; return AsyncStream { $0.yield(v); $0.finish() }
    }
    func tierBoardStream() -> AsyncStream<[TierBoardRow]> {
        let v = board; return AsyncStream { $0.yield(v); $0.finish() }
    }
    func theTopStream(filter: LibraryFilter) -> AsyncStream<[TopRow]> {
        let v = topRows; return AsyncStream { $0.yield(v); $0.finish() }
    }

    // MARK: Board mutation (mirrors RankMoves for `autoApplyMoves`)

    /// Remove a game from wherever it sits on the board.
    static func removeGame(_ board: [TierBoardRow], _ gameID: Int64) -> [TierBoardRow] {
        board.map { row in
            var r = row
            r.placed.removeAll { $0.id == gameID }
            r.unplaced.removeAll { $0.id == gameID }
            return r
        }
    }

    /// Apply one `move` to a board of summaries (insertion index is among the
    /// *other* placed games of the target tier; nil = unplaced tail).
    static func applyMove(_ board: [TierBoardRow], gameID: Int64, toTier: Int64, atIndex: Int?) -> [TierBoardRow] {
        // Find the moving summary, then strip it out everywhere.
        let moving = board.flatMap { $0.placed + $0.unplaced }.first { $0.id == gameID }
        guard var summary = moving else { return board }
        var result = removeGame(board, gameID)
        summary.tierID = toTier
        summary.tierLetter = result.first { $0.tier.id == toTier }?.tier.letter
        summary.tierColorHex = result.first { $0.tier.id == toTier }?.tier.colorHex
        guard let rowIndex = result.firstIndex(where: { $0.tier.id == toTier }) else { return board }
        if let atIndex {
            summary.rankKey = 1
            let clamped = max(0, min(atIndex, result[rowIndex].placed.count))
            result[rowIndex].placed.insert(summary, at: clamped)
        } else {
            summary.rankKey = nil
            result[rowIndex].unplaced.append(summary)
        }
        return result
    }

    // MARK: Covers
    func thumbnail(for coverFile: String, pixelSize: CGSize) async -> CGImage? { nil }
}

// MARK: - Sample builders

extension GameDetail {
    /// A minimal detail for previews / model tests.
    static func rankingSample(id: Int64, title: String, year: Int? = 2015,
                              platforms: [String] = ["ps4"], tier: TierInfo? = nil,
                              summary: String? = nil, genres: [String] = []) -> GameDetail {
        GameDetail(
            id: id, igdbID: nil, title: title, sortTitle: title.lowercased(),
            summary: summary, releaseDate: nil, year: year, decade: year.map { ($0 / 10) * 10 },
            played: true, owned: true, status: nil,
            tierID: tier?.id, tierLetter: tier?.letter, tierLabel: tier?.label,
            tierColorHex: tier?.colorHex, rankKey: nil,
            coverFile: nil, igdbCoverImageID: nil,
            genres: genres, platformIDs: platforms,
            myPlaytimeS: nil, psnPlaytimeS: nil, ttbHastilyS: nil, ttbNormallyS: nil,
            ttbCompletelyS: nil, ttbSource: nil,
            addedAt: .now, updatedAt: .now, copies: []
        )
    }
}

// MARK: - Preview factories

extension ScriptedRankingBackend {
    static func previewPlacement() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let s = TierInfo.defaults[0]
        b.details[1] = .rankingSample(id: 1, title: "Bloodborne", tier: s,
                                      summary: "A gothic action-RPG in Yharnam.",
                                      genres: ["Action", "RPG"])
        b.details[2] = .rankingSample(id: 2, title: "Elden Ring", year: 2022,
                                      platforms: ["ps5", "ps4"], tier: s,
                                      summary: "An open-world FromSoftware epic.",
                                      genres: ["Action", "RPG"])
        b.currentPrompt = DuelPrompt(kind: .placement, candidate: 1, opponent: 2,
                                     candidateTier: s.id, opponentTier: s.id,
                                     comparisonsMade: 2, estimatedTotal: 6)
        b.queueCount = 12
        b.stats = sampleStats()
        return b
    }

    static func previewRefine() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let a = TierInfo.defaults[1]
        b.details[3] = .rankingSample(id: 3, title: "Metal Gear Solid 3", year: 2004,
                                      platforms: ["ps2"], tier: a)
        b.details[4] = .rankingSample(id: 4, title: "Silent Hill 2", year: 2001,
                                      platforms: ["ps2"], tier: a)
        b.currentPrompt = DuelPrompt(kind: .refine, candidate: 3, opponent: 4,
                                     candidateTier: a.id, opponentTier: a.id,
                                     comparisonsMade: 0, estimatedTotal: 0)
        b.queueCount = 0
        return b
    }

    static func previewBorder() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let s = TierInfo.defaults[0], a = TierInfo.defaults[1]
        b.details[1] = .rankingSample(id: 1, title: "Bloodborne", tier: s)
        b.details[2] = .rankingSample(id: 2, title: "Sekiro", year: 2019, tier: a)
        b.currentPrompt = DuelPrompt(kind: .border, candidate: 1, opponent: 2,
                                     candidateTier: s.id, opponentTier: a.id,
                                     comparisonsMade: 0, estimatedTotal: 0)
        return b
    }

    static func previewEmpty() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.currentPrompt = nil
        b.stats = sampleStats()
        b.unranked = [GameSummary(id: 9, title: "Backlogged", played: true)]
        return b
    }

    static func previewTriage() -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        b.unranked = [
            GameSummary(id: 10, title: "Chrono Trigger", year: 1995, played: true, platformIDs: ["snes"]),
            GameSummary(id: 11, title: "Nier Automata", year: 2017, played: true, platformIDs: ["ps4"]),
            GameSummary(id: 12, title: "Hades", year: 2020, played: true, platformIDs: ["pc"]),
        ]
        return b
    }

    /// A Tier Board fake: `placedPerTier` fine-ranked games + `unplacedPerTier`
    /// dimmed-tail games per tier, plus a few unranked-tray games.
    static func previewBoard(placedPerTier: Int, unplacedPerTier: Int) -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let titles = ["Bloodborne", "Elden Ring", "Hades", "Celeste", "Hollow Knight",
                      "Nier Automata", "Chrono Trigger", "Dark Souls", "Portal 2", "Journey",
                      "Outer Wilds", "Disco Elysium", "Undertale", "Braid", "Inside"]
        let platforms = ["ps4", "ps5", "snes", "pc", "ps2"]
        var id: Int64 = 1
        b.board = TierInfo.defaults.map { tier in
            var placed: [GameSummary] = []
            for i in 0..<placedPerTier {
                placed.append(GameSummary(id: id, title: "\(titles[Int(id) % titles.count]) \(id)",
                                          year: 1995 + Int(id) % 30, tierID: tier.id,
                                          tierLetter: tier.letter, tierColorHex: tier.colorHex,
                                          rankKey: RankKey((i + 1) * 1000), played: true, owned: true,
                                          platformIDs: [platforms[Int(id) % platforms.count]]))
                id += 1
            }
            var unplaced: [GameSummary] = []
            for _ in 0..<unplacedPerTier {
                unplaced.append(GameSummary(id: id, title: "\(titles[Int(id) % titles.count]) \(id)",
                                            year: 1995 + Int(id) % 30, tierID: tier.id,
                                            tierLetter: tier.letter, tierColorHex: tier.colorHex,
                                            rankKey: nil, played: true, owned: true,
                                            platformIDs: [platforms[Int(id) % platforms.count]]))
                id += 1
            }
            return TierBoardRow(tier: tier, placed: placed, unplaced: unplaced)
        }
        b.unranked = (0..<4).map { i in
            GameSummary(id: 900 + Int64(i), title: "Untiered \(i)", year: 2010 + i,
                        played: true, owned: true, platformIDs: ["pc"])
        }
        return b
    }

    /// A The Top fake: `n` placed games across tiers with global + derived
    /// positions, optionally a filtered subset.
    static func previewTop(n: Int, filtered: Bool = false) -> ScriptedRankingBackend {
        let b = ScriptedRankingBackend()
        let titles = ["Bloodborne", "Elden Ring", "Hades", "Celeste", "Hollow Knight",
                      "Nier Automata", "Chrono Trigger", "Dark Souls", "Portal 2", "Journey",
                      "Outer Wilds", "Disco Elysium", "Undertale", "Braid", "Inside"]
        let platforms = ["ps4", "ps5", "snes", "pc", "ps2"]
        var rows: [TopRow] = []
        let tiers = TierInfo.defaults
        for i in 0..<n {
            let tier = tiers[min(i / max(1, n / 6 + 1), tiers.count - 1)]
            let game = GameSummary(id: Int64(i + 1), title: "\(titles[i % titles.count])",
                                   year: 1995 + i, tierID: tier.id, tierLetter: tier.letter,
                                   tierColorHex: tier.colorHex, rankKey: RankKey((i + 1) * 1000),
                                   played: true, owned: true,
                                   platformIDs: [platforms[i % platforms.count]])
            rows.append(TopRow(game: game, globalPosition: i + 1,
                               derivedPosition: filtered ? nil : i + 1))
        }
        if filtered {
            // Renumber the derived positions 1…k over the kept subset (every 2nd).
            var derived = 0
            rows = rows.enumerated().compactMap { idx, row in
                guard idx % 2 == 0 else { return nil }
                derived += 1
                return TopRow(game: row.game, globalPosition: row.globalPosition, derivedPosition: derived)
            }
        }
        b.topRows = rows
        return b
    }

    static func sampleStats() -> RankingStats {
        RankingStats(perTier: TierInfo.defaults.map { t in
            RankingStats.TierStat(tierID: t.id, letter: t.letter,
                                  placed: Int.random(in: 1...8), unplaced: 0)
        })
    }
}

// MARK: - Live-DB preview seed

/// Builds an in-memory database for a live-data preview / the end-to-end path.
enum PreviewRankingSeed {
    static func database(seed: [GameDraft] = []) async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        _ = try? await db.seedPlatformsFromBundle()
        let store = LibraryStore(db)
        for draft in seed { _ = try await store.addGame(draft) }
        return db
    }
}
#endif
