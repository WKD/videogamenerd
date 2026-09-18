import Foundation
import Testing
import GRDB
@testable import VGN

/// The data side of Play Next (PLAN §7b): the inputs loader (ownership incl.
/// compilation members + ROM copies, status rules), feedback persistence,
/// `startPlaying`, the second-opinion export, and performance.
@Suite struct RecommendationStoreTests {

    // Tier ids from the seed: S=1, A=2, B=3, C=4, D=5, F=6.

    private func makeStores() async throws -> (AppDatabase, LibraryStore, RecommendationStore) {
        let db = try await TestDB.makeSeeded()
        return (db, LibraryStore(db), RecommendationStore(db))
    }

    // MARK: - Candidate loader: ownership, status rules, ROM, compilation members

    @Test func candidateLoaderHonoursOwnershipAndStatus() async throws {
        let (db, lib, _) = try await makeStores()

        // Backlog (owned physical, unplayed).
        let backlog = try await lib.addGame(GameDraft(title: "Backlog", igdbID: 1,
                                                      platformIDs: ["ps4"], owned: true)).gameID
        // ROM backlog.
        let rom = try await lib.addGame(GameDraft(title: "ROM Game", igdbID: 2,
                                                  platformIDs: ["snes"], owned: true, format: .rom)).gameID
        // Playing.
        let playing = try await lib.addGame(GameDraft(title: "Playing", igdbID: 3,
                                                      platformIDs: ["ps4"], owned: true,
                                                      played: true, status: .playing)).gameID
        // Finished — never a candidate.
        let finished = try await lib.addGame(GameDraft(title: "Finished", igdbID: 4,
                                                       platformIDs: ["ps4"], owned: true,
                                                       played: true, status: .finished)).gameID
        // Played, no status — playedUnknown (excluded by default).
        let playedUnknown = try await lib.addGame(GameDraft(title: "PlayedNoStatus", igdbID: 5,
                                                            platformIDs: ["ps4"], owned: true, played: true)).gameID
        // Played but NOT owned — not a candidate (not owned).
        _ = try await lib.addGame(GameDraft(title: "PlayedNotOwned", igdbID: 6,
                                            platformIDs: ["ps4"], owned: false, played: true)).gameID
        // Compilation with two backlog members (owned via the product).
        let comp = try await lib.addCompilation(
            product: ProductDraft(platformID: "ps3", format: .physical),
            members: [CompilationMemberDraft(title: "Member One", igdbID: 7),
                      CompilationMemberDraft(title: "Member Two", igdbID: 8)])
        let member1 = comp.members[0].gameID

        let candidates = try await db.dbWriter.read { db in try RecommendationStore.loadCandidates(db: db) }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        #expect(byID[backlog]?.status == .backlog)
        #expect(byID[rom]?.formats.contains(.rom) == true)
        #expect(byID[playing]?.status == .playing)
        #expect(byID[finished] == nil)                       // finished excluded
        #expect(byID[playedUnknown]?.status == .playedUnknown)
        #expect(byID[member1]?.status == .backlog)           // compilation member is owned
        #expect(byID.count == 6)                             // not the not-owned played game
    }

    // MARK: - Features loaded (persisted traits + genre + platform + decade)

    @Test func featuresIncludeTraitsGenrePlatformDecade() async throws {
        let (db, lib, _) = try await makeStores()
        let id = try await lib.addGame(GameDraft(title: "Elden Ring", igdbID: 119133, year: 2022,
                                                 platformIDs: ["ps5"], owned: true)).gameID
        try await lib.updateMetadata(gameID: id, MetadataPatch(
            genres: ["Role-playing (RPG)"],
            traits: [GameTrait(kind: .developer, value: "FromSoftware")]))

        let features = try await db.dbWriter.read { db in
            try RecommendationStore.loadFeatures(ids: [id], db: db)
        }
        let traits = try #require(features[id]?.traits)
        #expect(traits.contains { $0.kind == .developer && $0.value == "FromSoftware" })
        #expect(traits.contains { $0.kind == .genre && $0.value == "Role-playing (RPG)" })
        #expect(traits.contains { $0.kind == .platform && $0.value == "ps5" })
        #expect(traits.contains { $0.kind == .decade && $0.value == "2020" })
    }

    // MARK: - End-to-end recommend

    @Test func recommendCrownsTasteMatch() async throws {
        let (db, lib, rec) = try await makeStores()
        _ = db

        // Taste: two FromSoftware games ranked high (S, A).
        let s = try await lib.addGame(GameDraft(title: "Bloodborne", igdbID: 100,
                                                platformIDs: ["ps4"], played: true, tierID: 1)).gameID
        let a = try await lib.addGame(GameDraft(title: "Dark Souls", igdbID: 101,
                                                platformIDs: ["ps4"], played: true, tierID: 2)).gameID
        for id in [s, a] {
            try await lib.updateMetadata(gameID: id, MetadataPatch(
                traits: [GameTrait(kind: .developer, value: "FromSoftware")]))
        }
        // A lower-ranked non-FromSoftware game (C).
        let c = try await lib.addGame(GameDraft(title: "Meh", igdbID: 102,
                                                platformIDs: ["ps4"], played: true, tierID: 4)).gameID
        try await lib.updateMetadata(gameID: c, MetadataPatch(traits: [GameTrait(kind: .developer, value: "Other")]))

        // Candidates: a FromSoftware backlog game vs a neutral one, both ~20 h.
        let fromSoft = try await lib.addGame(GameDraft(title: "Elden Ring", igdbID: 200,
                                                       platformIDs: ["ps5"], owned: true)).gameID
        let neutral = try await lib.addGame(GameDraft(title: "Neutral", igdbID: 201,
                                                      platformIDs: ["ps5"], owned: true)).gameID
        try await lib.updateMetadata(gameID: fromSoft, MetadataPatch(
            ttbNormallyS: Rec.hours(20), traits: [GameTrait(kind: .developer, value: "FromSoftware")]))
        try await lib.updateMetadata(gameID: neutral, MetadataPatch(
            ttbNormallyS: Rec.hours(20), traits: [GameTrait(kind: .developer, value: "Nobody")]))

        let result = try await rec.recommend(bracket: TimeBracket(preset: .month))
        #expect(result.hero?.id == fromSoft)
        #expect(result.hero?.platformIDs.contains("ps5") == true)
    }

    // MARK: - Feedback persistence

    @Test func feedbackSnoozeNeverAndStartPlaying() async throws {
        let (db, lib, rec) = try await makeStores()
        for i in 1...16 {
            _ = try await lib.addGame(GameDraft(title: "R\(i)", igdbID: Int64(i),
                                                platformIDs: ["ps4"], played: true, tierID: 3)).gameID
        }
        let cand = try await lib.addGame(GameDraft(title: "Cand", igdbID: 200,
                                                   platformIDs: ["ps4"], owned: true)).gameID
        let other = try await lib.addGame(GameDraft(title: "Other", igdbID: 201,
                                                    platformIDs: ["ps4"], owned: true)).gameID
        for id in [cand, other] {
            try await lib.updateMetadata(gameID: id, MetadataPatch(ttbNormallyS: Rec.hours(10)))
        }

        // never removes `other`; snooze removes `cand`.
        try await rec.never(gameID: other)
        try await rec.snooze(gameID: cand)
        let result = try await rec.recommend(bracket: TimeBracket(preset: .weekOrTwo))
        let shown = Set(result.shortlist.map(\.id))
        #expect(!shown.contains(other))
        #expect(!shown.contains(cand))
        #expect(result.exclusions.byFeedback == 2)

        // startPlaying sets status + logs a picked row.
        try await rec.startPlaying(gameID: cand)
        let row = try await db.dbWriter.read { db -> (String?, Int) in
            let status = try String.fetchOne(db, sql: "SELECT status FROM games WHERE id = ?", arguments: [cand])
            let picked = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rec_feedback WHERE game_id = ? AND action = 'picked'",
                                          arguments: [cand]) ?? 0
            return (status, picked)
        }
        #expect(row.0 == "playing")
        #expect(row.1 == 1)
    }

    // MARK: - Second-opinion export

    @Test func secondOpinionExportShape() async throws {
        let (_, lib, rec) = try await makeStores()
        // Top-ranked S game + an F "didn't click" game.
        _ = try await lib.addGame(GameDraft(title: "Masterpiece", igdbID: 1,
                                            platformIDs: ["ps4"], played: true, tierID: 1)).gameID
        _ = try await lib.addGame(GameDraft(title: "Awful", igdbID: 2,
                                            platformIDs: ["ps4"], played: true, tierID: 6)).gameID
        let cand = try await lib.addGame(GameDraft(title: "Backlog Pick", igdbID: 3,
                                                   platformIDs: ["ps5"], owned: true, format: .digital)).gameID
        try await lib.updateMetadata(gameID: cand, MetadataPatch(ttbNormallyS: Rec.hours(20)))

        let result = try await rec.recommend(bracket: TimeBracket(preset: .month))
        let request = try await rec.secondOpinionRequest(for: result)
        #expect(request.topRanked.contains { $0.title == "Masterpiece" && $0.tier == "S" })
        #expect(request.didntClick.contains { $0.title == "Awful" && $0.tier == "F" })
        #expect(request.shortlist.contains { $0.id == cand && $0.engineRank == 1 })
        #expect(request.engineOrdering.first == cand)
        // Round-trips as Codable (what leaves the app).
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(SecondOpinionRequest.self, from: data) == request)
    }

    // MARK: - Performance

    @Test func performanceAt100And2000Games() async throws {
        for size in [100, 2000] {
            let (db, lib, rec) = try await makeStores()
            try await seedLibrary(size: size, lib: lib, db: db)

            // Warm one read, then time recommend.
            _ = try await rec.recommend(bracket: TimeBracket(preset: .month))
            let start = Date()
            let result = try await rec.recommend(bracket: TimeBracket(preset: .month))
            let ms = Date().timeIntervalSince(start) * 1000
            print("PERF recommend @\(size) games: \(String(format: "%.1f", ms)) ms, hero=\(result.hero?.id.description ?? "nil")")
            // Correctness only — the timing is printed for the handoff, never
            // asserted (a wall-clock ceiling flakes under parallel test load).
            #expect(result.hero != nil)
        }
    }

    /// Bulk-seed: half the games ranked (played + tiered) with traits, half owned
    /// backlog with traits + an estimate — inserted in one transaction each.
    private func seedLibrary(size: Int, lib: LibraryStore, db: AppDatabase) async throws {
        let developers = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        try await db.dbWriter.write { db in
            for i in 0..<size {
                let ranked = i % 2 == 0
                let tier: Int64 = Int64(1 + (i % 6))
                try db.execute(sql: """
                    INSERT INTO games (id, igdb_id, title, played, tier_id, ttb_normally_s,
                                       igdb_rating, igdb_rating_count, year)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        Int64(i + 1), Int64(10000 + i), "Game \(i)",
                        ranked ? 1 : 0, ranked ? tier : nil,
                        72000 + (i % 40) * 3600,          // 20–60 h
                        70.0 + Double(i % 30), 100 + i, 2000 + (i % 25)])
                // Ownership for the backlog half.
                if !ranked {
                    try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source) VALUES (?, 'ps4', 'single', 'physical', 'manual')",
                                   arguments: [Int64(i + 1)])
                    try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                                   arguments: [Int64(i + 1), Int64(i + 1)])
                }
                // Traits: a developer + two similar ids.
                try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (?, 'developer', ?)",
                               arguments: [Int64(i + 1), developers[i % developers.count]])
                try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (?, 'similar', ?)",
                               arguments: [Int64(i + 1), String(10000 + ((i + 1) % size))])
                try db.execute(sql: "INSERT INTO game_traits (game_id, kind, value) VALUES (?, 'keyword', ?)",
                               arguments: [Int64(i + 1), "kw-\(i % 10)"])
            }
        }
    }
}
