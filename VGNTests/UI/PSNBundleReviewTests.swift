import Foundation
import GRDB
import Testing
@testable import VGN

/// PSN bundles expand too (PLAN §13.3, W18-A): a PSN bundle match commits as ONE compilation
/// Product per ownership kind (purchase / PS Plus / played-no-purchase physical+digital), or no
/// product for played-not-owned (only the ticked members are added). "Which did you play?" is
/// asked once in the row; the collection's play time / dates / status land on a member only when
/// exactly one is ticked. Re-sync is idempotent. No network.
@MainActor
@Suite(.serialized)
struct PSNBundleReviewTests {
    private let first = Date(timeIntervalSince1970: 1_600_000_000)
    private let last = Date(timeIntervalSince1970: 1_650_000_000)

    private static let platforms: [PlatformCatalogEntry] = [
        .init(id: "ps5", name: "PlayStation 5", short: "PS5", manufacturer: "Sony",
              group: "Console", kind: "console", generation: 9, igdbIDs: [167], libretroRepo: nil, sort: 1),
        .init(id: "ps4", name: "PlayStation 4", short: "PS4", manufacturer: "Sony",
              group: "Console", kind: "console", generation: 8, igdbIDs: [48], libretroRepo: nil, sort: 2),
        .init(id: "pc", name: "PC", short: "PC", manufacturer: "Microsoft",
              group: "Computer", kind: "computer", generation: nil, igdbIDs: [6], libretroRepo: nil, sort: 3),
    ]

    private func member(_ igdbID: Int64, _ title: String, position: Int) -> CompilationMemberDraft {
        CompilationMemberDraft(title: title, igdbID: igdbID, position: position)
    }

    /// Build a PSN review model holding one bundle row `b1` with `members` members.
    private func makeModel(
        row: ImportStagingRow,
        members: [CompilationMemberDraft],
        db: AppDatabase
    ) async throws -> (model: ImportReviewModel, staging: ImportStagingStore) {
        let staging = ImportStagingStore(db)
        try await staging.upsert([row])
        let outcome = ScanMatchOutcome(
            best: ScanMatch(igdbID: 900, name: row.name, releaseYear: nil, coverImageID: nil,
                            platformSlugs: [row.platform ?? "ps5"], score: 0.98,
                            matchedName: row.name, gameType: .bundle),
            alternatives: [], bucket: .confident)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn, stagedTotal: 1, newCount: 1),
            matches: [ImportMatchResult(externalID: row.externalID, name: row.name, outcome: outcome)],
            rows: [row],
            bundleExpansions: [row.externalID: ImportBundleExpansion(
                bundleIGDBID: 900, title: row.name, members: members)])
        let m = ImportReviewModel(
            source: ImportSourceID.psn, sourceLabel: "PlayStation", staging: staging,
            result: result, productFormat: .digital, platformChoices: ["ps5", "ps4", "pc"])
        await m.load()
        return (m, staging)
    }

    private func seededDB() async throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try await db.seedPlatforms(from: Self.platforms)
        return db
    }

    // Reads.
    private func compilationProducts(_ db: AppDatabase) async throws -> [Row] {
        try await db.dbWriter.read {
            try Row.fetchAll($0, sql: "SELECT format, subscription FROM products WHERE kind = 'compilation'")
        }
    }
    private func gamesCount(_ db: AppDatabase) async throws -> Int {
        try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM games") ?? -1 }
    }
    private func productsCount(_ db: AppDatabase) async throws -> Int {
        try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM products") ?? -1 }
    }
    private func game(igdbID: Int64, _ db: AppDatabase) async throws -> GameRecord? {
        try await db.dbWriter.read { try GameRecord.filter(GameRecord.Columns.igdbID == igdbID).fetchOne($0) }
    }

    // MARK: - Ownership kinds (D1)

    @Test(.timeLimit(.minutes(2)))
    func purchaseBundleCommitsOneDigitalCompilation() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "BioShock: The Collection", platform: "ps4", signals: [.owned])
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "BioShock", position: 0), member(2, "BioShock 2", position: 1),
                                 member(3, "BioShock Infinite", position: 2)], db: db)
        m.setInclude(true, externalID: "b1")
        _ = try await staging.commit(m.commitItems())

        let comps = try await compilationProducts(db)
        #expect(comps.count == 1)
        #expect(comps.first?["format"] == ProductFormat.digital.rawValue)
        #expect((comps.first?["subscription"] as String?) == nil)
        #expect(try await gamesCount(db) == 3)     // 3 members created, none played
        for id: Int64 in [1, 2, 3] { #expect(try await game(igdbID: id, db)?.played == false) }
    }

    @Test(.timeLimit(.minutes(2)))
    func psPlusBundleCommitsSubscriptionCompilation() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Mega Man Legacy Collection", platform: "ps4",
                                   signals: [.owned], subscription: .psPlus)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "Mega Man", position: 0), member(2, "Mega Man 2", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        _ = try await staging.commit(m.commitItems())

        let comps = try await compilationProducts(db)
        #expect(comps.count == 1)
        #expect((comps.first?["subscription"] as String?) == "ps_plus")
    }

    @Test(.timeLimit(.minutes(2)))
    func playedNoPurchaseBundleOwnAsPhysical() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Uncharted: The Nathan Drake Collection", platform: "ps4",
                                   signals: [.played], playDurationS: 7200)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "Drake's Fortune", position: 0),
                                member(2, "Among Thieves", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        m.applyOwnAs(.physical)
        _ = try await staging.commit(m.commitItems())

        let comps = try await compilationProducts(db)
        #expect(comps.count == 1)
        #expect(comps.first?["format"] == ProductFormat.physical.rawValue)

        // Digital variant.
        let db2 = try await seededDB()
        let (m2, staging2) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db2)
        m2.setInclude(true, externalID: "b1")
        m2.applyOwnAs(.digital)
        _ = try await staging2.commit(m2.commitItems())
        #expect(try await compilationProducts(db2).first?["format"] == ProductFormat.digital.rawValue)
    }

    @Test(.timeLimit(.minutes(2)))
    func playedNotOwnedBundleAddsOnlyTickedMembers() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Some Played Collection", platform: "ps4",
                                   signals: [.played], playDurationS: 7200)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "One", position: 0), member(2, "Two", position: 1),
                                member(3, "Three", position: 2)], db: db)
        m.setInclude(true, externalID: "b1")
        // ownAs stays nil (played, not owned) — tick just one member as played.
        m.setBundleMemberPlayed(true, position: 0, externalID: "b1")
        _ = try await staging.commit(m.commitItems())

        // No product at all; only the one ticked member was created (as played-not-owned).
        #expect(try await productsCount(db) == 0)
        #expect(try await gamesCount(db) == 1)
        #expect(try await game(igdbID: 1, db)?.played == true)
        #expect(try await game(igdbID: 2, db) == nil)
    }

    // MARK: - Played ticks routing (D2)

    @Test(.timeLimit(.minutes(2)))
    func playedTicksNoneMarksNoMemberPlayed() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Collection", platform: "ps4",
                                   signals: [.owned, .played], playDurationS: 9000)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        _ = try await staging.commit(m.commitItems())
        // All members owned; none played; play time not routed to any member.
        #expect(try await game(igdbID: 1, db)?.played == false)
        #expect(try await game(igdbID: 1, db)?.psnPlaytimeS == nil)
        #expect(try await game(igdbID: 2, db)?.psnPlaytimeS == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func playedTicksOneRoutesPlayData() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Collection", platform: "ps4",
                                   signals: [.owned, .played], playDurationS: 9000,
                                   firstPlayedAt: first, lastPlayedAt: last, statusPrefill: .completed)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        m.setBundleMemberPlayed(true, position: 1, externalID: "b1")   // exactly one
        _ = try await staging.commit(m.commitItems())

        let target = try #require(try await game(igdbID: 2, db))
        #expect(target.played == true)
        #expect(target.psnPlaytimeS == 9000)
        #expect(target.status == PlayStatus.completed.rawValue)
        // The other member is owned-not-played and carries no play time.
        let other = try #require(try await game(igdbID: 1, db))
        #expect(other.played == false)
        #expect(other.psnPlaytimeS == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func playedTicksSeveralMarkPlayedButRouteNoPlayData() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Collection", platform: "ps4",
                                   signals: [.owned, .played], playDurationS: 9000, statusPrefill: .completed)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        m.setAllBundleMembersPlayed(true, externalID: "b1")   // several
        #expect(m.bundlePlayedCount(m.rows[0]) == 2)
        _ = try await staging.commit(m.commitItems())

        // Both played, but neither gets the collection's play time or status (stays on the record).
        for id: Int64 in [1, 2] {
            let g = try #require(try await game(igdbID: id, db))
            #expect(g.played == true)
            #expect(g.psnPlaytimeS == nil)
            #expect(g.status == nil)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func asksPlayedOnlyWhenCollectionPlayed() async throws {
        let db = try await seededDB()
        // Played collection → asks.
        let playedRow = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1", name: "C",
                                         platform: "ps4", signals: [.owned, .played], playDurationS: 9000)
        let (m1, _) = try await makeModel(row: playedRow,
                                          members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        #expect(m1.psnBundleAsksPlayed(m1.rows[0]))

        // A collection PSN reports as never played asks nothing.
        let db2 = try await seededDB()
        let unplayedRow = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1", name: "C",
                                           platform: "ps4", signals: [.owned])
        let (m2, _) = try await makeModel(row: unplayedRow,
                                          members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db2)
        #expect(!m2.psnBundleAsksPlayed(m2.rows[0]))
    }

    // MARK: - Re-sync idempotency (D3)

    @Test(.timeLimit(.minutes(2)))
    func resyncOfCompilationAddsNothing() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "BioShock: The Collection", platform: "ps4", signals: [.owned])
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        _ = try await staging.commit(m.commitItems())
        let games1 = try await gamesCount(db)
        let products1 = try await productsCount(db)

        // Commit the very same items again — the (source, external_id) product is reused.
        _ = try await staging.commit(m.commitItems())
        #expect(try await gamesCount(db) == games1)
        #expect(try await productsCount(db) == products1)
    }

    // MARK: - Vault / Launched treat the bundle as one row

    @Test(.timeLimit(.minutes(1)))
    func launchedBundleCountsAsOneRow() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                   name: "Never-played Collection", platform: "ps4",
                                   signals: [], launchedNotPlayed: true)
        let (m, _) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        // The whole bundle is one Launched row → one Vault send at commit, not one per member.
        #expect(m.psnGroup(for: m.rows[0]) == .launched)
        #expect(m.launchedVaultCount == 1)
    }

    private func matchedGameID(_ db: AppDatabase, _ externalID: String) async throws -> Int64? {
        try await db.dbWriter.read {
            try Int64.fetchOne($0, sql: "SELECT matched_game_id FROM import_titles WHERE external_id = ?",
                               arguments: [externalID])
        }
    }

    // MARK: - Remembered single-played member (D3)

    @Test(.timeLimit(.minutes(2)))
    func remembersSinglePlayedMemberAsMatchedGame() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1", name: "Collection",
                                   platform: "ps4", signals: [.owned, .played], playDurationS: 9000)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        m.setBundleMemberPlayed(true, position: 1, externalID: "b1")   // exactly one: B
        _ = try await staging.commit(m.commitItems())
        // The staging row remembers B (matched_game_id) so re-sync routes play data to it.
        let bID = try #require(try await game(igdbID: 2, db))?.id
        #expect(try await matchedGameID(db, "b1") == bID)
        #expect(try await game(igdbID: 2, db)?.psnPlaytimeS == 9000)
    }

    @Test(.timeLimit(.minutes(2)))
    func remembersFirstMemberWhenSeveralPlayed() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1", name: "Collection",
                                   platform: "ps4", signals: [.owned, .played], playDurationS: 9000)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "b1")
        m.setAllBundleMembersPlayed(true, externalID: "b1")   // several
        _ = try await staging.commit(m.commitItems())
        let aID = try #require(try await game(igdbID: 1, db))?.id
        #expect(try await matchedGameID(db, "b1") == aID)     // first member
    }

    // MARK: - Cross-gen twin folding (D5)

    @Test(.timeLimit(.minutes(1)))
    func crossGenTwinIsFoldedUnderOneRow() async throws {
        let db = try await seededDB()
        let staging = ImportStagingStore(db)
        // Two entitlements PSNMapping did not merge (different ids), both matching IGDB game 42.
        let ps4 = ImportStagingRow(source: ImportSourceID.psn, externalID: "ps4id",
                                   name: "Man of Medan PS4", platform: "ps4", signals: [.owned])
        let ps5 = ImportStagingRow(source: ImportSourceID.psn, externalID: "ps5id",
                                   name: "Man of Medan PS5", platform: "ps5", signals: [.owned])
        try await staging.upsert([ps4, ps5])
        func matched(_ ext: String, _ platform: String) -> ImportMatchResult {
            ImportMatchResult(externalID: ext, name: "Man of Medan", outcome: ScanMatchOutcome(
                best: ScanMatch(igdbID: 42, name: "Man of Medan", releaseYear: nil, coverImageID: nil,
                                platformSlugs: [platform], score: 0.95, matchedName: "Man of Medan"),
                alternatives: [], bucket: .confident))
        }
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn),
            matches: [matched("ps4id", "ps4"), matched("ps5id", "ps5")], rows: [ps4, ps5])
        let m = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                  staging: staging, result: result, productFormat: .digital,
                                  platformChoices: ["ps5", "ps4"])
        await m.load()
        // The ps5 row is kept (newest); the ps4 row folds under it.
        let kept = try #require(m.rows.first { $0.externalID == "ps5id" })
        let folded = try #require(m.rows.first { $0.externalID == "ps4id" })
        #expect(kept.twinFoldedInto == nil)
        #expect(folded.twinFoldedInto == "ps5id")
        #expect(kept.alsoOnNote == "also: PS4 & PS5 version")
        // Only the kept row is committable / shown; the folded one is hidden and never commits.
        #expect(!folded.isCommittable)
        #expect(m.psnRows(in: .purchased).contains { $0.externalID == "ps5id" })
        #expect(!m.psnRows(in: .purchased).contains { $0.externalID == "ps4id" })
    }

    // MARK: - Collection playtime read (item 4 data layer)

    @Test(.timeLimit(.minutes(1)))
    func collectionPlaytimeShownOnlyWhenNotRoutedToOneMember() async throws {
        let db = try await seededDB()
        let staging = ImportStagingStore(db)
        let store = LibraryStore(db)
        try await staging.upsert([ImportStagingRow(source: ImportSourceID.psn, externalID: "coll",
                                                   name: "Collection", platform: "ps4",
                                                   signals: [.owned, .played], playDurationS: 270_000)])
        // No match_json yet → collection carries the time.
        #expect(try await store.collectionPlaytimeSeconds(source: ImportSourceID.psn, externalID: "coll") == 270_000)
        // Several members played → still on the collection.
        try await recordBundle(staging, externalID: "coll", playedIndices: [0, 1])
        #expect(try await store.collectionPlaytimeSeconds(source: ImportSourceID.psn, externalID: "coll") == 270_000)
        // Exactly one member played → routed to that member, so the collection line is hidden.
        try await recordBundle(staging, externalID: "coll", playedIndices: [0])
        #expect(try await store.collectionPlaytimeSeconds(source: ImportSourceID.psn, externalID: "coll") == nil)
        // No record at all → nil.
        #expect(try await store.collectionPlaytimeSeconds(source: ImportSourceID.psn, externalID: "nope") == nil)
    }

    @Test(.timeLimit(.minutes(2)))
    func compilationCopyExposesCollectionPlaytimeThroughDetail() async throws {
        let db = try await seededDB()
        let row = ImportStagingRow(source: ImportSourceID.psn, externalID: "coll", name: "Collection",
                                   platform: "ps4", signals: [.owned, .played], playDurationS: 270_000)
        let (m, staging) = try await makeModel(
            row: row, members: [member(1, "A", position: 0), member(2, "B", position: 1)], db: db)
        m.setInclude(true, externalID: "coll")
        _ = try await staging.commit(m.commitItems())
        let store = LibraryStore(db)
        let aID = try #require(try await game(igdbID: 1, db)?.id)

        // Several members played → the time stays on the collection → the detail copy exposes it.
        try await recordBundle(staging, externalID: "coll", playedIndices: [0, 1])
        let copy1 = try #require(try await store.gameDetail(id: aID)?.copies.first(where: \.isCompilation))
        #expect(copy1.collectionPlaytimeS == 270_000)
        #expect(PlaytimeParser.format(seconds: 270_000) == "75 h")   // the caption string

        // Exactly one played → routed to that member → no collection caption.
        try await recordBundle(staging, externalID: "coll", playedIndices: [0])
        let copy2 = try #require(try await store.gameDetail(id: aID)?.copies.first(where: \.isCompilation))
        #expect(copy2.collectionPlaytimeS == nil)
    }

    private func recordBundle(_ staging: ImportStagingStore, externalID: String, playedIndices: Set<Int>) async throws {
        var members = [member(1, "A", position: 0), member(2, "B", position: 1)]
        for i in members.indices { members[i].played = playedIndices.contains(i) }
        let outcome = ScanMatchOutcome(
            best: ScanMatch(igdbID: 900, name: "Collection", releaseYear: nil, coverImageID: nil,
                            platformSlugs: ["ps4"], score: 0.9, matchedName: "Collection", gameType: .bundle),
            alternatives: [], bucket: .confident)
        try await staging.recordMatchOutcome(
            source: ImportSourceID.psn, externalID: externalID,
            PersistedImportMatch(outcome: outcome, bundle: ImportBundleExpansion(
                bundleIGDBID: 900, title: "Collection", members: members)))
    }

    // MARK: - Empty state (D6)

    @Test(.timeLimit(.minutes(1)))
    func emptyReviewReportsNothingToReview() async throws {
        let db = try await seededDB()
        let staging = ImportStagingStore(db)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: [])
        let m = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                  staging: staging, result: result, productFormat: .digital)
        await m.load()
        #expect(m.hasNothingToReview)
    }
}

/// Title cleaning for MATCHING drops the platform tails Sony appends (PLAN §13.3 / D5). The
/// displayed name is never changed; only the IGDB-match title is cleaned. Pure — no I/O.
struct PSNTitleTailTests {

    @Test func dropsBareCrossGenTail() {
        #expect(PSNMapping.cleanMatchTitle("The Dark Pictures Anthology: Man of Medan PS4 & PS5")
                == "The Dark Pictures Anthology: Man of Medan")
        #expect(PSNMapping.cleanMatchTitle("Aliens: Fireteam Elite PS4 & PS5")
                == "Aliens: Fireteam Elite")
    }

    @Test func dropsTrademarkedTail() {
        // ™ is stripped first, then the "PS4 & PS5" tail.
        #expect(PSNMapping.cleanMatchTitle("Ghost of Tsushima PS4™ & PS5™") == "Ghost of Tsushima")
    }

    @Test func dropsParentheticalAndForAndSingleTail() {
        #expect(PSNMapping.cleanMatchTitle("Returnal (PS5)") == "Returnal")
        #expect(PSNMapping.cleanMatchTitle("Hades (PS4/PS5)") == "Hades")
        #expect(PSNMapping.cleanMatchTitle("Gran Turismo 7 PS5") == "Gran Turismo 7")
        #expect(PSNMapping.cleanMatchTitle("Death Stranding for PS4") == "Death Stranding")
    }

    @Test func leavesRealTitlesAlone() {
        // Counter-cases: no platform token, or a token that is part of a real name — untouched.
        #expect(PSNMapping.cleanMatchTitle("Persona 5") == "Persona 5")
        #expect(PSNMapping.cleanMatchTitle("NBA 2K21") == "NBA 2K21")
        #expect(PSNMapping.cleanMatchTitle("Katamari Damacy") == "Katamari Damacy")
        #expect(PSNMapping.cleanMatchTitle("Horizon Forbidden West") == "Horizon Forbidden West")
        // A title that is ONLY a platform token is never stripped to empty.
        #expect(PSNMapping.cleanMatchTitle("PS4") == "PS4")
    }
}
