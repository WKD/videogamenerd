import Foundation
import GRDB
import Testing
@testable import VGN

/// Bundles to Expand — batch "Expand All Unplayed" + candidate-by-IGDB-type + the played-placeholder
/// expand sheet (PLAN §13.3 / §5.1 D4). No network — members come from an injected fake seam.
@MainActor
@Suite(.serialized)
struct BundleBatchExpandTests {

    @discardableResult
    private func addGame(_ store: LibraryStore, title: String, igdbID: Int64,
                         played: Bool = false, tierID: Int64? = nil, rankKey: Int64? = nil,
                         myPlaytimeS: Int? = nil) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: igdbID, title: title, sortTitle: SortTitle.make(from: title),
                               played: played, tierID: tierID, rankKey: rankKey, myPlaytimeS: myPlaytimeS)
            try g.insert(db)
            return g.id!
        }
    }

    private func addSingleProduct(_ store: LibraryStore, gameID: Int64, platform: String) async throws {
        try await store.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO products (platform_id, kind, format, source) VALUES (?, 'single', 'physical', 'manual')",
                           arguments: [platform])
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, gameID])
            try db.execute(sql: "INSERT INTO game_platforms (game_id, platform_id, played) VALUES (?, ?, 0) ON CONFLICT DO NOTHING",
                           arguments: [gameID, platform])
        }
    }

    /// Attach a persisted import match saying "bundle" to a game (no title hint needed).
    private func markMatchJSONBundle(_ store: LibraryStore, gameID: Int64, externalID: String,
                                     name: String) async throws {
        let staging = ImportStagingStore(store.database)
        try await staging.upsert([ImportStagingRow(source: ImportSourceID.psn, externalID: externalID,
                                                    name: name, platform: "ps4", signals: [.owned])])
        let outcome = ScanMatchOutcome(
            best: ScanMatch(igdbID: 700, name: name, releaseYear: nil, coverImageID: nil,
                            platformSlugs: ["ps4"], score: 0.9, matchedName: name, gameType: .bundle),
            alternatives: [], bucket: .confident)
        let json = ImportStagingStore.encodeMatch(PersistedImportMatch(outcome: outcome, bundle: nil))
        try await store.dbWriter.write { db in
            try db.execute(sql: "UPDATE import_titles SET matched_game_id = ?, match_json = ? WHERE source = ? AND external_id = ?",
                           arguments: [gameID, json, ImportSourceID.psn, externalID])
        }
    }

    nonisolated private func member(_ igdbID: Int64, _ title: String, _ position: Int) -> CompilationMemberDraft {
        CompilationMemberDraft(title: title, igdbID: igdbID, position: position)
    }
    private func compilationCount(_ store: LibraryStore) async throws -> Int {
        try await store.dbReader.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM products WHERE kind = 'compilation'") ?? -1 }
    }
    private func game(_ store: LibraryStore, igdbID: Int64) async throws -> GameRecord? {
        try await store.dbReader.read { try GameRecord.filter(GameRecord.Columns.igdbID == igdbID).fetchOne($0) }
    }

    // MARK: - D4a: candidate detection by IGDB type

    @Test(.timeLimit(.minutes(1)))
    func candidateDetectedByIGDBTypeWithNoTitleHint() async throws {
        let store = try await TestDB.makeStore()
        // Title has no Trilogy/Collection/Pack hint, so the title heuristic alone would miss it.
        let id = try await addGame(store, title: "Castlevania Requiem: Symphony of the Night & Rondo of Blood",
                                   igdbID: 700)
        try await addSingleProduct(store, gameID: id, platform: "ps4")
        // Not a candidate yet (no title hint, no match).
        let before = try await store.bundleExpansionCandidates()
        #expect(!before.contains { $0.gameID == id })
        // Persisted match says bundle → now a candidate.
        try await markMatchJSONBundle(store, gameID: id, externalID: "cv", name: "Castlevania Requiem")
        let after = try await store.bundleExpansionCandidates()
        #expect(after.contains { $0.gameID == id })
    }

    // MARK: - D4b: Expand All Unplayed batch

    @Test(.timeLimit(.minutes(2)))
    func batchExpandsBundlesDismissesNonBundlesWithOneUndo() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "Alpha Collection", igdbID: 10)
        try await addSingleProduct(store, gameID: a, platform: "ps4")
        let b = try await addGame(store, title: "Beta Trilogy", igdbID: 20)
        try await addSingleProduct(store, gameID: b, platform: "ps4")
        let c = try await addGame(store, title: "Gamma Collection", igdbID: 30)   // IGDB: not a bundle
        try await addSingleProduct(store, gameID: c, platform: "ps4")

        let candidates = try await store.unplayedBundleExpansionCandidates()
        #expect(candidates.count == 3)

        let model = BundleBatchExpandModel(store: store, membersOf: { cand in
            switch cand.igdbID {
            case 10: return ([self.member(11, "A1", 0), self.member(12, "A2", 1)], [])
            case 20: return ([self.member(21, "B1", 0), self.member(22, "B2", 1)], [])
            default: return ([], [])   // Gamma → not a bundle
            }
        })
        await model.run(candidates)
        #expect(model.phase == .confirming)
        #expect(model.bundleRows.count == 2)
        #expect(model.notBundleRows.count == 1)
        // Gamma was auto-dismissed → no longer a candidate.
        let afterDismiss = try await store.bundleExpansionCandidates()
        #expect(!afterDismiss.contains { $0.gameID == c })

        await model.confirm()
        #expect(model.phase == .done)
        #expect(model.expandedCount == 2)
        #expect(model.undoRecords.count == 2)             // one undo record per game, one batch
        #expect(try await compilationCount(store) == 2)

        // Undo the whole batch — both compilations gone, singles restored.
        await model.undoBatch()
        #expect(try await compilationCount(store) == 0)
        #expect(try await game(store, igdbID: 10) != nil)  // Alpha restored
    }

    @Test(.timeLimit(.minutes(1)))
    func cancelStopsFetchingAndExpandsNothing() async throws {
        let store = try await TestDB.makeStore()
        let a = try await addGame(store, title: "Alpha Collection", igdbID: 10)
        try await addSingleProduct(store, gameID: a, platform: "ps4")
        let model = BundleBatchExpandModel(store: store, membersOf: { _ in ([self.member(11, "A1", 0)], []) })
        model.cancel()   // cancel before running → the loop breaks at the first item
        await model.run(try await store.unplayedBundleExpansionCandidates())
        #expect(model.phase == .done)
        #expect(model.results.isEmpty)
        await model.confirm()                     // no-op: not in the confirming phase
        #expect(model.expandedCount == 0)
        #expect(try await compilationCount(store) == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func unplayedSkipsPlayedCandidates() async throws {
        let store = try await TestDB.makeStore()
        let unplayed = try await addGame(store, title: "Unplayed Collection", igdbID: 10)
        try await addSingleProduct(store, gameID: unplayed, platform: "ps4")
        let played = try await addGame(store, title: "Played Collection", igdbID: 20, played: true)
        try await addSingleProduct(store, gameID: played, platform: "ps4")

        let all = try await store.bundleExpansionCandidates()
        #expect(all.count == 2)
        let unplayedOnly = try await store.unplayedBundleExpansionCandidates()
        #expect(unplayedOnly.map(\.gameID) == [unplayed])
    }

    // MARK: - D4c: played-placeholder expand sheet

    @Test func playedPlaceholderModelMemberTicksAndExactlyOneRule() async throws {
        let model = BundleExpansionModel(
            gameID: 1, bundleTitle: "Coll", members: [member(1, "A", 0), member(2, "B", 1), member(3, "C", 2)],
            carriesPlayData: true, isPlayed: true, isRanked: false)
        // Default none ticked.
        #expect(model.playedCount == 0)
        #expect(model.effectiveTargetIndex == model.playDataTargetIndex)   // falls back to the picker/first
        // Tick exactly one → the exactly-one rule targets it.
        model.toggle(1, true)
        #expect(model.singlePlayedIndex == 1)
        #expect(model.effectiveTargetIndex == 1)
        #expect(model.resolvedMembers[1].played == true)
        #expect(model.resolvedMembers[0].played == false)
        // Tick a second → no single member; play data falls back to the tier/rank target.
        model.toggle(2, true)
        #expect(model.singlePlayedIndex == nil)
        #expect(model.effectiveTargetIndex == model.playDataTargetIndex)
        // All / None.
        model.playedAll(); #expect(model.playedCount == 3)
        model.playedNone(); #expect(model.playedCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func expandPlayedPlaceholderRoutesPlayDataToTickedMember() async throws {
        let store = try await TestDB.makeStore()
        let placeholder = try await addGame(store, title: "Played Collection", igdbID: 500,
                                            played: true, myPlaytimeS: 7200)
        try await addSingleProduct(store, gameID: placeholder, platform: "ps4")
        // Model: played placeholder, tick member B (index 1) as the one played.
        let model = BundleExpansionModel(
            gameID: placeholder, bundleTitle: "Played Collection",
            members: [member(1, "A", 0), member(2, "B", 1)],
            carriesPlayData: true, isPlayed: true, isRanked: false)
        model.toggle(1, true)
        _ = try await store.expandBundle(
            gameID: placeholder, bundleTitle: "Played Collection",
            members: model.resolvedMembers, playDataTargetIndex: model.effectiveTargetIndex)
        // The ticked member B is played and inherited the placeholder's playtime; A is not played.
        let b = try #require(try await game(store, igdbID: 2))
        #expect(b.played == true)
        #expect(b.myPlaytimeS == 7200)
        let a = try #require(try await game(store, igdbID: 1))
        #expect(a.played == false)
    }
}
