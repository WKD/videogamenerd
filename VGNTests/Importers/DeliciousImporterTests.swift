import Foundation
import Testing
@testable import VGN

/// An in-memory DB seeded with the real platform catalogue (Delicious games span
/// consoles + PC/Mac), shared by the importer + duplicate suites.
enum DeliciousTestDB {
    static func makeSeeded() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        _ = try await db.seedPlatforms(from: PlatformCatalog.entriesFromBundle())
        return db
    }
}

private func cleanupStore(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Importer → coordinator → staging: original titles kept, platforms mapped, the cleaned
/// title used for matching, and the file-flavoured summary.
struct DeliciousImporterStagingTests {

    @Test(.timeLimit(.minutes(1)))
    func stagesEveryGameWithMappedPlatforms() async throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Heavy Rain PS3 - édition spéciale", platforms: ["PlayStation 3"]),
            .init(uuid: "b", title: "Cérébrale Académie", platforms: ["Nintendo DS"]),
            .init(uuid: "c", title: "Baldur's Gate 2 DVD Rom", platforms: ["Windows XP", "Mac OS X"]),
        ])
        defer { cleanupStore(url) }

        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let importer = DeliciousImporter(reader: DeliciousLibraryReader(url: url))
        let coordinator = ImportSyncCoordinator(staging: staging)
        let result = try await coordinator.run(importer, matcher: NoMatchImportMatcher())

        #expect(result.summary.fromFile == 3)
        #expect(result.summary.summaryLine(sourceLabel: "Delicious Library")
                    == "3 games read from Delicious Library")

        let titles = try await staging.titles(source: ImportSourceID.delicious)
        #expect(titles.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: titles.map { ($0.externalID, $0) })
        #expect(byID["a"]?.name == "Heavy Rain PS3 - édition spéciale")   // original kept
        #expect(byID["a"]?.platform == "ps3")
        #expect(byID["b"]?.platform == "ds")
        #expect(byID["c"]?.platform == "mac")                              // hybrid, default policy
    }

    @Test(.timeLimit(.minutes(1)))
    func matchesTheCleanedTitleNotTheNoisyOriginal() async throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "a", title: "Heavy Rain PS3 - édition spéciale", platforms: ["PlayStation 3"]),
        ])
        defer { cleanupStore(url) }
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let importer = DeliciousImporter(reader: DeliciousLibraryReader(url: url))
        let matcher = FakeImportMatcher()
        _ = try await ImportSyncCoordinator(staging: staging).run(importer, matcher: matcher)
        #expect(matcher.requests.map(\.title) == ["Heavy Rain"])   // scrubbed, not the raw title
    }

    @Test(.timeLimit(.minutes(1)))
    func alwaysPCPolicyMapsHybridToPC() async throws {
        let url = try DeliciousTestStore.make([
            .init(uuid: "c", title: "Hybrid Game", platforms: ["Windows XP", "Mac OS X"]),
        ])
        defer { cleanupStore(url) }
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let importer = DeliciousImporter(reader: DeliciousLibraryReader(url: url), platformPolicy: .alwaysPC)
        _ = try await ImportSyncCoordinator(staging: staging).run(importer, matcher: NoMatchImportMatcher())
        let titles = try await staging.titles(source: ImportSourceID.delicious)
        #expect(titles.first?.platform == "pc")
    }
}

/// The "discard duplicate copies" rule (PLAN §5.5): same physical copy already on the
/// shelf → Already matched, unticked; digital-only → importable; other platform →
/// importable; two rows same game+platform → import one.
@MainActor
@Suite(.serialized)
struct DeliciousDuplicateTests {

    private func match(_ igdbID: Int64, _ name: String, slugs: [String]) -> ScanMatch {
        ScanMatch(igdbID: igdbID, name: name, releaseYear: nil, coverImageID: nil,
                  platformSlugs: slugs, score: 0.97, matchedName: name)
    }

    /// Seed one owned copy of `format` on `platform` for a game with `igdbID`.
    private func seedOwned(_ store: LibraryStore, igdbID: Int64, platform: String,
                           format: ProductFormat) async throws {
        try await store.addGame(GameDraft(
            title: "Owned \(igdbID)", igdbID: igdbID, platformIDs: [platform],
            owned: true, format: format, source: .photo))
    }

    /// Build a loaded review model for one delicious row matched to `igdbID` on `platform`.
    private func loadedModel(db: AppDatabase, staging: ImportStagingStore,
                             igdbID: Int64, platform: String, extraRows: [ImportStagingRow] = [],
                             extraMatches: [ImportMatchResult] = []) async throws -> ImportReviewModel {
        let row = ImportStagingRow(source: ImportSourceID.delicious, externalID: "d1",
                                   name: "Delicious Game", platform: platform)
        try await staging.upsert([row] + extraRows)
        let matches = [ImportMatchResult(
            externalID: "d1", name: "Delicious Game",
            outcome: ScanMatchOutcome(best: match(igdbID, "Delicious Game", slugs: [platform]),
                                      alternatives: [], bucket: .confident))] + extraMatches
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.delicious, fromFile: 1 + extraRows.count),
            matches: matches, rows: [row] + extraRows)
        let m = ImportReviewModel(
            source: ImportSourceID.delicious, sourceLabel: "Delicious Library", staging: staging,
            result: result, productFormat: .physical, platformChoices: ["ps3", "ps2", "pc", "mac"],
            detectShelfDuplicates: true)
        await m.load()
        return m
    }

    @Test(.timeLimit(.minutes(1)))
    func physicalCopyAlreadyOnShelfIsDiscarded() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        try await seedOwned(LibraryStore(db), igdbID: 500, platform: "ps3", format: .physical)
        let m = try await loadedModel(db: db, staging: staging, igdbID: 500, platform: "ps3")
        let row = try #require(m.rows.first { $0.externalID == "d1" })
        #expect(row.shelfDuplicate == true)
        #expect(row.bucket == .alreadyMatched)
        #expect(row.isCommittable == false)
        #expect(m.committableCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func digitalCopyOnlyStaysImportable() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        try await seedOwned(LibraryStore(db), igdbID: 501, platform: "ps3", format: .digital)
        let m = try await loadedModel(db: db, staging: staging, igdbID: 501, platform: "ps3")
        let row = try #require(m.rows.first { $0.externalID == "d1" })
        #expect(row.shelfDuplicate == false)
        #expect(row.bucket == .new)
        #expect(row.duplicateNote != nil)   // "you already own a different copy"
    }

    @Test(.timeLimit(.minutes(1)))
    func sameGameOtherPlatformIsImportable() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        try await seedOwned(LibraryStore(db), igdbID: 502, platform: "ps2", format: .physical)
        let m = try await loadedModel(db: db, staging: staging, igdbID: 502, platform: "ps3")
        let row = try #require(m.rows.first { $0.externalID == "d1" })
        #expect(row.shelfDuplicate == false)
        #expect(row.bucket == .new)
        #expect(row.duplicateNote == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func twoRowsSameGameAndPlatformImportOne() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let second = ImportStagingRow(source: ImportSourceID.delicious, externalID: "d2",
                                      name: "Delicious Game", platform: "ps3")
        let secondMatch = ImportMatchResult(
            externalID: "d2", name: "Delicious Game",
            outcome: ScanMatchOutcome(best: match(600, "Delicious Game", slugs: ["ps3"]),
                                      alternatives: [], bucket: .confident))
        let m = try await loadedModel(db: db, staging: staging, igdbID: 600, platform: "ps3",
                                      extraRows: [second], extraMatches: [secondMatch])
        let dupes = m.rows.filter { $0.shelfDuplicate }
        #expect(dupes.count == 1)                     // one of the two flagged
        #expect(m.committableCount == 1)              // the other imports
    }
}

/// The cover fallback DB setter (PLAN §5.5): sets a cover only where empty, without the
/// user-chosen marker.
@MainActor
@Suite(.serialized)
struct DeliciousCoverSetterTests {

    @Test(.timeLimit(.minutes(1)))
    func setsCoverOnlyWhenEmptyAndNeverUserChosen() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let store = LibraryStore(db)
        let outcome = try await store.addGame(GameDraft(title: "Cover Me", igdbID: 700,
                                                        platformIDs: ["ps3"], owned: true, source: .photo))
        let gameID = outcome.gameID

        #expect(try await store.setImportedCoverIfEmpty(gameID: gameID, coverFile: "700-abcd.jpg") == true)
        // Not marked user-edited, so enrichment may still upgrade it.
        let userEdited = try await db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT user_edited FROM games WHERE id = ?", arguments: [gameID]) ?? ""
        }
        #expect(!userEdited.contains("cover"))
        // A second call is a no-op (a cover already exists).
        #expect(try await store.setImportedCoverIfEmpty(gameID: gameID, coverFile: "700-zzzz.jpg") == false)
        let coverFile = try await db.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT cover_file FROM games WHERE id = ?", arguments: [gameID])
        }
        #expect(coverFile == "700-abcd.jpg")
    }
}
