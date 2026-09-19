import Foundation
import GRDB
import Testing
@testable import VGN

/// The Delicious commit payload (needs the v7 schema): a physical product carrying the
/// source, external id, edition and acquired date; the new game's origin; and an
/// idempotent re-import.
@MainActor
@Suite(.serialized)
struct DeliciousCommitTests {

    private func item(edition: String? = "Special Edition",
                      acquiredAt: Date? = Date(timeIntervalSince1970: 1_300_000_000)) -> ImportCommitItem {
        ImportCommitItem(
            source: ImportSourceID.delicious, externalID: "u1", platformID: "ps3",
            format: .physical,
            target: .newGame(ImportNewGameSpec(title: "Heavy Rain", igdbID: 101, releaseYear: 2010)),
            edition: edition, acquiredAt: acquiredAt)
    }

    @Test(.timeLimit(.minutes(1)))
    func commitCreatesPhysicalProductWithSourceEditionDateAndOrigin() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let result = try await staging.commit([item()])
        #expect(result.gamesCreated == 1)
        #expect(result.productsAdded == 1)

        struct P: Sendable { var source, format, externalID, platformID: String
                             var edition, origin: String?; var hasAcquired: Bool }
        let p = try await db.dbWriter.read { db -> P? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT p.source AS source, p.format AS format, p.external_id AS external_id,
                       p.edition AS edition, p.acquired_at AS acquired_at, p.platform_id AS platform_id,
                       g.origin AS origin
                FROM products p
                JOIN product_games pg ON pg.product_id = p.id
                JOIN games g ON g.id = pg.game_id
                WHERE p.source = 'delicious'
                """) else { return nil }
            return P(source: row["source"], format: row["format"], externalID: row["external_id"],
                     platformID: row["platform_id"], edition: row["edition"], origin: row["origin"],
                     hasAcquired: (row["acquired_at"] as Date?) != nil)
        }
        let r = try #require(p)
        #expect(r.source == "delicious")
        #expect(r.format == "physical")
        #expect(r.externalID == "u1")
        #expect(r.edition == "Special Edition")
        #expect(r.platformID == "ps3")
        #expect(r.hasAcquired)
        #expect(r.origin == "delicious")   // v6 origin set from the import source
    }

    @Test(.timeLimit(.minutes(1)))
    func reimportIsIdempotent() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        _ = try await staging.commit([item()])
        let second = try await staging.commit([item()])
        #expect(second.skippedExisting == 1)
        #expect(second.productsAdded == 0)
        #expect(second.gamesCreated == 0)

        let productCount = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source='delicious'")
        }
        #expect(productCount == 1)   // no second copy
    }
}
