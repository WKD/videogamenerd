import Foundation
import GRDB
import Testing
@testable import VGN

/// Import review sheet, bundle expansion (PLAN §5.1, owner bug 2026-09-20): a bundle match
/// commits as a **compilation** Product whose members are the individual games (deduped
/// against the library), it is idempotent on re-import, and an empty member list falls back
/// to a single. No network.
@MainActor
@Suite(.serialized)
struct ImportReviewBundleTests {

    private func staged(_ ext: String, _ name: String, platform: String = "pc") -> ImportStagingRow {
        ImportStagingRow(source: ImportSourceID.delicious, externalID: ext, name: name, platform: platform)
    }

    private func bundleOutcome(_ igdbID: Int64, _ name: String) -> ScanMatchOutcome {
        ScanMatchOutcome(
            best: ScanMatch(igdbID: igdbID, name: name, releaseYear: nil, coverImageID: nil,
                            platformSlugs: ["pc"], score: 0.97, matchedName: name, gameType: .bundle),
            alternatives: [], bucket: .confident)
    }

    private func member(_ igdbID: Int64, _ title: String, position: Int) -> CompilationMemberDraft {
        CompilationMemberDraft(title: title, igdbID: igdbID, position: position)
    }

    /// A staged Tomb Raider Trilogy row + a matching bundle expansion of 3 members.
    private func trilogyResult(members: [CompilationMemberDraft]) -> ImportSyncResult {
        ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.delicious, stagedTotal: 1, newCount: 1),
            matches: [ImportMatchResult(externalID: "b1", name: "The Tomb Raider Trilogy",
                                        outcome: bundleOutcome(500, "The Tomb Raider Trilogy"))],
            rows: [staged("b1", "The Tomb Raider Trilogy")],
            bundleExpansions: ["b1": ImportBundleExpansion(
                bundleIGDBID: 500, title: "The Tomb Raider Trilogy", members: members)])
    }

    private func gamesCount(_ db: AppDatabase) async throws -> Int {
        try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM games") ?? -1 }
    }
    private func compilationProducts(_ db: AppDatabase) async throws -> Int {
        try await db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM products WHERE kind = 'compilation'") ?? -1
        }
    }
    private func gamesWithIGDB(_ db: AppDatabase, _ igdbID: Int64) async throws -> Int {
        try await db.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM games WHERE igdb_id = ?", arguments: [igdbID]) ?? -1
        }
    }

    // MARK: - Tests

    @Test(.timeLimit(.minutes(1)))
    func bundleRowBecomesCompilationOutcome() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let result = trilogyResult(members: [
            member(1, "Tomb Raider: Legend", position: 0),
            member(2, "Tomb Raider: Anniversary", position: 1),
            member(3, "Tomb Raider: Underworld", position: 2)])
        try await staging.upsert(result.rows)
        let m = ImportReviewModel(source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
                                  staging: staging, result: result, productFormat: .physical,
                                  platformChoices: ["pc"])
        await m.load()
        let row = try #require(m.rows.first { $0.externalID == "b1" })
        #expect(row.isBundleExpansion)
        #expect(row.bundleMembers.count == 3)

        let items = m.commitItems()
        let item = try #require(items.first { $0.externalID == "b1" })
        if case .compilation(let title, let members) = item.target {
            #expect(title == "The Tomb Raider Trilogy")
            #expect(members.count == 3)
        } else { Issue.record("expected a compilation target") }
    }

    @Test(.timeLimit(.minutes(2)))
    func commitCreatesCompilationAndDedupesExistingMember() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let store = LibraryStore(db)
        // An existing library game already IS one of the members (igdb 2).
        try await store.dbWriter.write { db in
            var g = GameRecord(igdbID: 2, title: "Tomb Raider: Anniversary",
                               sortTitle: SortTitle.make(from: "Tomb Raider: Anniversary"))
            try g.insert(db)
        }
        let staging = ImportStagingStore(db)
        let result = trilogyResult(members: [
            member(1, "Tomb Raider: Legend", position: 0),
            member(2, "Tomb Raider: Anniversary", position: 1),
            member(3, "Tomb Raider: Underworld", position: 2)])
        try await staging.upsert(result.rows)
        let m = ImportReviewModel(source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
                                  staging: staging, result: result, productFormat: .physical,
                                  platformChoices: ["pc"])
        await m.load()
        m.commit()
        await poll(2_000, until: { m.committed })

        // 3 games total (1 pre-existing + 2 new); the existing member is linked, not duplicated.
        let games = try await gamesCount(db)
        #expect(games == 3)
        let dupCheck = try await gamesWithIGDB(db, 2)
        #expect(dupCheck == 1)
        let comps = try await compilationProducts(db)
        #expect(comps == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func secondImportOfTheSameBundleAddsNothing() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let members = [member(1, "A", position: 0), member(2, "B", position: 1)]
        let result = trilogyResult(members: members)
        try await staging.upsert(result.rows)

        let first = ImportReviewModel(source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
                                      staging: staging, result: result, productFormat: .physical,
                                      platformChoices: ["pc"])
        await first.load()
        first.commit()
        await poll(2_000, until: { first.committed })
        let gamesAfterFirst = try await gamesCount(db)
        let compsAfterFirst = try await compilationProducts(db)

        // A second commit of the same (source, external_id) creates nothing new.
        let second = ImportStagingStore(db)
        let secondResult = try await second.commit(first.commitItems())
        #expect(secondResult.gamesCreated == 0)
        #expect(secondResult.productsAdded == 0)
        #expect(secondResult.skippedExisting == 1)
        let gamesAfterSecond = try await gamesCount(db)
        let compsAfterSecond = try await compilationProducts(db)
        #expect(gamesAfterSecond == gamesAfterFirst)
        #expect(compsAfterSecond == compsAfterFirst)
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyMemberListFallsBackToSingle() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let result = trilogyResult(members: [])   // IGDB had no member list
        try await staging.upsert(result.rows)
        let m = ImportReviewModel(source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
                                  staging: staging, result: result, productFormat: .physical,
                                  platformChoices: ["pc"])
        await m.load()
        let row = try #require(m.rows.first { $0.externalID == "b1" })
        #expect(!row.isBundleExpansion)
        let item = try #require(m.commitItems().first { $0.externalID == "b1" })
        if case .newGame = item.target {} else { Issue.record("expected a single newGame target") }
    }

    @Test(.timeLimit(.minutes(1)))
    func psnNeverExpandsBundles() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        // Same shape, but the source is PSN → bundle expansions are ignored (PLAN §13.3).
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn, stagedTotal: 1, newCount: 1),
            matches: [ImportMatchResult(externalID: "b1", name: "Some Collection",
                                        outcome: bundleOutcome(500, "Some Collection"))],
            rows: [ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                    name: "Some Collection", platform: "ps3", signals: [.owned])],
            bundleExpansions: ["b1": ImportBundleExpansion(
                bundleIGDBID: 500, title: "Some Collection",
                members: [member(1, "A", position: 0)])])
        try await staging.upsert(result.rows)
        let m = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                  staging: staging, result: result, productFormat: .digital,
                                  platformChoices: ["pc"])
        await m.load()
        let row = try #require(m.rows.first { $0.externalID == "b1" })
        #expect(!row.isBundleExpansion)
    }
}
