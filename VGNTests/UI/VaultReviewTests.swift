import Foundation
import Testing
@testable import VGN

/// The review sheet's Vault-related behaviour (PLAN §16 + coordinator 2026-09-20): the
/// collapsed "In the Vault (N)" group for auto-vaulted claims, promotion-on-play linking, the
/// platform-policy capability flag, and the PSN group "ticked / total" count. In-memory; no
/// network.
@MainActor
@Suite(.serialized)
struct VaultReviewTests {

    private func psnModel(_ rows: [ImportStagingRow]) async throws -> (ImportReviewModel, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: rows)
        let model = ImportReviewModel(
            source: ImportSourceID.psn, sourceLabel: "PlayStation", staging: staging,
            result: result, productFormat: .digital, platformChoices: PSNImportPresenter.platformChoices)
        await model.load()
        return (model, db)
    }

    @Test(.timeLimit(.minutes(1)))
    func vaultedClaimsGroupSeparatelyFromIgnored() async throws {
        let (model, _) = try await psnModel([
            ImportStagingRow(source: ImportSourceID.psn, externalID: "vaulted", name: "Barely Played",
                             platform: "ps5", signals: [.owned],
                             ignoreReason: .vaultedSubscription, subscription: .psPlus),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "noise", name: "Netflix",
                             platform: "ps5", signals: [.owned], ignoreReason: .mediaApp),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "buy", name: "Stray",
                             platform: "ps5", signals: [.owned]),
        ])
        let vaulted = model.rows.first { $0.externalID == "vaulted" }!
        let noise = model.rows.first { $0.externalID == "noise" }!
        #expect(model.psnGroup(for: vaulted) == .inTheVault)
        #expect(model.psnGroup(for: noise) == .ignored)
        #expect(model.presentPSNGroups.contains(.inTheVault))
        #expect(model.presentPSNGroups.contains(.ignored))
        // A vaulted row is never committed.
        #expect(!vaulted.isCommittable)
    }

    @Test(.timeLimit(.minutes(1)))
    func groupTickedCountReflectsUnticking() async throws {
        let (model, _) = try await psnModel([
            ImportStagingRow(source: ImportSourceID.psn, externalID: "a", name: "A", platform: "ps5", signals: [.owned]),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "b", name: "B", platform: "ps5", signals: [.owned]),
        ])
        #expect(model.psnTickedCount(in: .purchased) == 2)
        model.setInclude(false, externalID: "a")
        #expect(model.psnTickedCount(in: .purchased) == 1)
    }

    @Test func platformPolicyCapabilityDefaultsOffAndGOGOptsIn() throws {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        let result = ImportSyncResult(summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: [])
        let psn = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                    staging: staging, result: result)
        #expect(!psn.showsPlatformPolicy)                // PSN: no pc/mac switch
        let gog = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                    result: ImportSyncResult(summary: ImportSyncSummary(source: "gog"), matches: [], rows: []),
                                    showsPlatformPolicy: true)
        #expect(gog.showsPlatformPolicy)
    }

    @Test(.timeLimit(.minutes(1)))
    func promotionLinkingLinksVaultRowToNewGame() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // A PS Plus Vault row for a claim that later crosses the gate.
        _ = try await store.syncPSNVault(
            entries: [RomCatalogEntry.makePSNVault(externalID: "ent:9", platform: "ps5",
                                                   name: "Crossed", coverURL: nil, membership: "ps_plus")],
            presentExternalIDs: ["ent:9"])
        // The importer commits it as an owned-via-subscription copy (game + product).
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, sort_title, played) VALUES (77, 'Crossed', 'crossed', 1)")
            try db.execute(sql: """
                INSERT INTO products (id, platform_id, kind, format, source, external_id, subscription)
                VALUES (88, 'ps5', 'single', 'digital', 'psn', 'ent:9', 'ps_plus')
                """)
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (88, 77, 0)")
        }
        try await store.linkPromotedFromProducts(source: "psn")
        let entries = try await store.browse(source: VaultSource.psn.storage, system: nil,
                                             filter: .all, sort: .title, search: "", limit: 10, offset: 0)
        #expect(entries.first?.promotedGameID == 77)
    }
}
