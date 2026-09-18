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
    var unranked: [GameSummary] = []
    var queueCount = 0
    var stats = RankingStats(perTier: [])
    var disputes: [Consistency.Dispute] = []
    var setTierResult: SetTierOutcome?

    // Recorded calls
    private(set) var answered: [Int64] = []
    private(set) var skipCount = 0
    private(set) var undoCount = 0
    private(set) var accepted: [BorderSuggestion] = []
    private(set) var dismissed: [BorderSuggestion] = []
    private(set) var rePlaced: [Int64] = []
    private(set) var tierCalls: [(ids: [Int64], tierID: Int64?)] = []

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

    // MARK: Reads
    func gameDetail(id: Int64) async throws -> GameDetail? { details[id] }
    func tiers() async throws -> [TierInfo] { tierList }
    func tierBoardOnce() async throws -> [TierBoardRow] { board }
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
