import Foundation
import Testing
import GRDB
@testable import VGN

/// Migration v12 (PLAN §16 "Send to the Vault"): `rom_catalog.owned` (nullable-defaulted flag).
/// Fresh DB has it defaulting to 0; an upgrade from v11 keeps every row and adds the column
/// defaulting to 0. Also covers the store's `sendToVault` / `deleteEntries` / owned round-trip.
@Suite struct MigrationV12Tests {

    @Test func freshDBHasOwnedColumnDefaultingZero() async throws {
        let db = try AppDatabase.inMemory()
        try await db.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog (source, system, platform_id, relative_path, name,
                    sort_title, normalised_title, first_seen_at, last_seen_at)
                VALUES ('psn','ps5',NULL,'ent:1','A','a','a', ?, ?)
                """, arguments: [Date(), Date()])
        }
        let owned = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT owned FROM rom_catalog WHERE relative_path = 'ent:1'")
        }
        #expect(owned == 0)
    }

    @Test func upgradeFromV11KeepsRowsAndAddsOwned() async throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)

        var upToV11 = DatabaseMigrator()
        Migrations.registerV1(in: &upToV11)
        Migrations.registerV2(in: &upToV11)
        Migrations.registerV3(in: &upToV11)
        Migrations.registerV4(in: &upToV11)
        Migrations.registerV5(in: &upToV11)
        Migrations.registerV6(in: &upToV11)
        Migrations.registerV7(in: &upToV11)
        Migrations.registerV8(in: &upToV11)
        Migrations.registerV9(in: &upToV11)
        Migrations.registerV10(in: &upToV11)
        Migrations.registerV11(in: &upToV11)
        try upToV11.migrate(queue)

        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO rom_catalog (source, system, platform_id, relative_path, name,
                    sort_title, normalised_title, first_seen_at, last_seen_at)
                VALUES ('psn','ps5',NULL,'ent:1','A','a','a', ?, ?),
                       ('batocera','snes',NULL,'./m.zip','M','m','m', ?, ?)
                """, arguments: [Date(), Date(), Date(), Date()])
        }
        let before = try await queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1 }

        var full = upToV11
        Migrations.registerV12(in: &full)
        try full.migrate(queue)

        let (count, zeros) = try await queue.read { db -> (Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rom_catalog WHERE owned = 0") ?? -1)
        }
        #expect(count == before)   // no rows lost
        #expect(zeros == before)   // every existing row defaults to not-owned
    }

    @Test(.timeLimit(.minutes(1)))
    func sendToVaultPersistsOwnedAndDeleteReverses() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)

        var owned = RomCatalogEntry.makePSNVault(externalID: "buy:1", platform: "ps5",
                                                 name: "Purchased Game", coverURL: nil, membership: nil)
        owned.owned = true
        owned.igdbID = 55
        let result = try await store.sendToVault([owned])
        #expect(result.insertedIDs.count == 1)

        let row = try await store.entry(id: result.insertedIDs[0])
        #expect(row?.owned == true)
        #expect(row?.igdbID == 55)
        #expect(row?.isPSPlusSubscription == false)   // owned ⇒ no PS Plus term

        // A re-send updates rather than duplicates.
        let again = try await store.sendToVault([owned])
        #expect(again.updatedIDs.count == 1)
        #expect(try await store.sourceCounts().psn == 1)

        // Undo hard-deletes the created rows.
        try await store.deleteEntries(ids: result.insertedIDs)
        #expect(try await store.sourceCounts().psn == 0)
    }
}
