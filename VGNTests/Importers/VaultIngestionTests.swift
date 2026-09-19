import Foundation
import Testing
@testable import VGN

/// The Vault ingestion path (PLAN §16): the coordinator carries an importer's PS Plus vault
/// entries through into ``ImportSyncResult`` (empty for other sources), and upserting them into
/// ``RomCatalogStore`` lands them as a separate shelf — invisible to the library.
@Suite(.serialized) struct VaultIngestionTests {

    /// A tiny fake importer that returns preset staging rows + vault entries.
    private struct FakeImporter: LibraryImporter {
        let source = ImportSourceID.psn
        var dataSets: [ImportDataSet] { [] }
        var vaultEntries: [RomCatalogEntry] = []
        var vaultPresentIDs: Set<String> = []
        func authenticate() async throws {}
        func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
            ImportFetchResult(rows: [], vaultEntries: vaultEntries, vaultPresentIDs: vaultPresentIDs)
        }
    }

    @Test func coordinatorCarriesVaultEntriesThrough() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)

        let entry = RomCatalogEntry.makePSNVault(externalID: "ent:1", platform: "ps5",
                                                 name: "Bloodborne", coverURL: "https://x/bb.png",
                                                 membership: "ps_plus")
        let importer = FakeImporter(vaultEntries: [entry], vaultPresentIDs: ["ent:1"])
        let result = try await coordinator.run(importer, matcher: NoMatchImportMatcher())

        #expect(result.vaultEntries.count == 1)
        #expect(result.vaultPresentIDs == ["ent:1"])

        // Upserting into the store lands it as a PS Plus Vault row.
        let store = RomCatalogStore(db)
        _ = try await store.syncPSNVault(entries: result.vaultEntries,
                                         presentExternalIDs: result.vaultPresentIDs)
        #expect(try await store.sourceCounts().psn == 1)

        // The library is untouched (no games created by a Vault upsert).
        let games = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? -1
        }
        #expect(games == 0)
    }
}
