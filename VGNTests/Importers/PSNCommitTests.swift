import Foundation
import Testing
import GRDB
@testable import VGN

/// The additive PSN commit path (PLAN §13.3): played-without-a-copy, PSN play time, status
/// pre-fill, the PS Plus flag, idempotency, the disappeared-claim proposal, and the two
/// cross-import orders. GOG/Delicious behaviour is untouched (their suites stay green).
@Suite struct PSNCommitTests {

    private func makeStores() async throws -> (AppDatabase, ImportStagingStore) {
        let db = try await TestDB.makeSeeded()
        return (db, ImportStagingStore(db))
    }

    private func playedOnly(externalID: String, title: String, platform: String = "ps5",
                            playtime: Int? = nil, status: PlayStatus? = nil,
                            igdbID: Int64? = nil) -> ImportCommitItem {
        ImportCommitItem(
            source: ImportSourceID.psn, externalID: externalID, platformID: platform,
            format: .digital,
            target: .newGame(ImportNewGameSpec(title: title, igdbID: igdbID)),
            psn: PSNCommit(createProduct: false, markPlayed: true,
                           playDurationS: playtime, statusPrefill: status))
    }

    private func purchase(externalID: String, title: String, platform: String = "ps5",
                          subscription: String? = nil, igdbID: Int64? = nil) -> ImportCommitItem {
        ImportCommitItem(
            source: ImportSourceID.psn, externalID: externalID, platformID: platform,
            format: .digital,
            target: .newGame(ImportNewGameSpec(title: title, igdbID: igdbID)),
            psn: PSNCommit(createProduct: true, subscription: subscription, markPlayed: false))
    }

    private func read<T: DatabaseValueConvertible & Sendable>(_ db: AppDatabase, _ sql: String, _ args: StatementArguments = StatementArguments()) async throws -> T? {
        try await db.dbWriter.read { try T.fetchOne($0, sql: sql, arguments: args) }
    }

    // MARK: - Played-only

    @Test func playedOnlyCreatesNoCopy() async throws {
        let (db, staging) = try await makeStores()
        let result = try await staging.commit([playedOnly(externalID: "npwr:1", title: "Borrowed Game", playtime: 3600)])
        #expect(result.gamesCreated == 1)
        #expect(result.productsAdded == 0)
        let played: Bool? = try await read(db, "SELECT played FROM games WHERE title = 'Borrowed Game'")
        let products: Int? = try await read(db, "SELECT COUNT(*) FROM products")
        let psn: Int? = try await read(db, "SELECT psn_playtime_s FROM games WHERE title = 'Borrowed Game'")
        #expect(played == true)
        #expect(products == 0)         // played, not owned — no copy
        #expect(psn == 3600)
    }

    // MARK: - Playtime update, manual wins

    @Test func psnPlaytimeUpdatesButNeverOverwritesManual() async throws {
        let (db, staging) = try await makeStores()
        try await staging.commit([playedOnly(externalID: "npwr:2", title: "Timed Title", playtime: 3600)])
        let gid: Int64 = try await read(db, "SELECT id FROM games WHERE title = 'Timed Title'")!
        // The owner types a manual playtime.
        try await db.dbWriter.write { try $0.execute(sql: "UPDATE games SET my_playtime_s = 9999 WHERE id = ?", arguments: [gid]) }
        // A re-sync with a changed PSN playtime updates psn_playtime_s only.
        try await staging.commit([ImportCommitItem(
            source: ImportSourceID.psn, externalID: "npwr:2", platformID: "ps5",
            target: .existingGame(gameID: gid),
            psn: PSNCommit(createProduct: false, markPlayed: true, playDurationS: 7200))])
        let manual: Int? = try await read(db, "SELECT my_playtime_s FROM games WHERE id = ?", [gid])
        let psn: Int? = try await read(db, "SELECT psn_playtime_s FROM games WHERE id = ?", [gid])
        #expect(manual == 9999)   // manual untouched
        #expect(psn == 7200)      // PSN value updated
    }

    // MARK: - Status pre-fill only when none

    @Test func statusPrefillOnlyWhenGameHasNone() async throws {
        let (db, staging) = try await makeStores()
        try await staging.commit([playedOnly(externalID: "npwr:3", title: "Hundred Percent", status: .completed)])
        let gid: Int64 = try await read(db, "SELECT id FROM games WHERE title = 'Hundred Percent'")!
        var status: String? = try await read(db, "SELECT status FROM games WHERE id = ?", [gid])
        #expect(status == "completed")
        // The owner changes it to 'playing'; a later pre-fill must not overwrite it.
        try await db.dbWriter.write { try $0.execute(sql: "UPDATE games SET status = 'playing' WHERE id = ?", arguments: [gid]) }
        try await staging.commit([ImportCommitItem(
            source: ImportSourceID.psn, externalID: "npwr:3", platformID: "ps5",
            target: .existingGame(gameID: gid),
            psn: PSNCommit(createProduct: false, markPlayed: true, statusPrefill: .completed))])
        status = try await read(db, "SELECT status FROM games WHERE id = ?", [gid])
        #expect(status == "playing")
    }

    // MARK: - Subscription flag + idempotency

    @Test func psPlusFlagAndIdempotentResync() async throws {
        let (db, staging) = try await makeStores()
        let first = try await staging.commit([purchase(externalID: "ent:1", title: "Plus Game", subscription: "ps_plus")])
        #expect(first.productsAdded == 1)
        let sub: String? = try await read(db, "SELECT subscription FROM products WHERE external_id = 'ent:1'")
        #expect(sub == "ps_plus")
        // A second identical commit adds nothing.
        let second = try await staging.commit([purchase(externalID: "ent:1", title: "Plus Game", subscription: "ps_plus")])
        #expect(second.productsAdded == 0)
        let count: Int? = try await read(db, "SELECT COUNT(*) FROM products WHERE external_id = 'ent:1'")
        #expect(count == 1)
    }

    // MARK: - Disappeared PS Plus claim → proposed, never applied

    @Test func disappearedPlusClaimIsProposedNotRemoved() async throws {
        let (db, staging) = try await makeStores()
        try await staging.commit([purchase(externalID: "ent:9", title: "Expiring Plus", subscription: "ps_plus")])
        // Still present in the latest sync → no proposal.
        let present = try await staging.proposedSubscriptionRemovals(
            source: ImportSourceID.psn, currentExternalIDs: ["ent:9"])
        #expect(present.isEmpty)
        // Gone from the latest sync → proposed for removal, but the copy still exists.
        let proposals = try await staging.proposedSubscriptionRemovals(
            source: ImportSourceID.psn, currentExternalIDs: ["ent:other"])
        #expect(proposals.count == 1)
        #expect(proposals.first?.externalID == "ent:9")
        #expect(proposals.first?.gameTitle == "Expiring Plus")
        let stillThere: Int? = try await read(db, "SELECT COUNT(*) FROM products WHERE external_id = 'ent:9'")
        #expect(stillThere == 1)   // never applied silently
    }

    // MARK: - Cross-import (PLAN §13.3 "Physical or digital?")

    @Test func photoDiscThenPSNAddsPlayedNoNewCopy() async throws {
        let (db, staging) = try await makeStores()
        let store = LibraryStore(db)
        // Photo scan added a physical disc for an IGDB-identified game.
        let outcome = try await store.addGames([GameDraft(
            title: "Disc Game", igdbID: 4242, platformIDs: ["ps5"], owned: true,
            format: .physical, source: .photo)])
        let gid = outcome[0].gameID
        // PSN sync (rule 1: already in library) → played only, no new copy.
        try await staging.commit([ImportCommitItem(
            source: ImportSourceID.psn, externalID: "npwr:disc", platformID: "ps5",
            target: .existingGame(gameID: gid),
            psn: PSNCommit(createProduct: false, markPlayed: true, playDurationS: 1000))])
        let products: Int? = try await read(db, "SELECT COUNT(*) FROM products")
        let played: Bool? = try await read(db, "SELECT played FROM games WHERE id = ?", [gid])
        #expect(products == 1)      // the disc, no PSN copy
        #expect(played == true)
    }

    @Test func psnPlayedOnlyThenPhotoScanAttachesTheDisc() async throws {
        let (db, staging) = try await makeStores()
        let store = LibraryStore(db)
        // PSN created a played-only game with an IGDB id.
        try await staging.commit([playedOnly(externalID: "npwr:pd", title: "Later Disc", igdbID: 7777)])
        // A later photo scan of the same IGDB game attaches the physical copy (dedupe on igdb_id).
        let outcome = try await store.addGames([GameDraft(
            title: "Later Disc", igdbID: 7777, platformIDs: ["ps5"], owned: true,
            format: .physical, source: .photo)])
        let games: Int? = try await read(db, "SELECT COUNT(*) FROM games WHERE igdb_id = 7777")
        let played: Bool? = try await read(db, "SELECT played FROM games WHERE id = ?", [outcome[0].gameID])
        let products: Int? = try await read(db, "SELECT COUNT(*) FROM products")
        #expect(games == 1)         // one game, not two
        #expect(played == true)     // still played
        #expect(products == 1)      // the newly-attached disc
    }
}
