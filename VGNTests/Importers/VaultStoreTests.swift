import Foundation
import Testing
@testable import VGN

/// The Vault side of ``RomCatalogStore`` (PLAN §16): PS Plus upsert / removal, per-source
/// counts in one observation, the IGDB trait pass (batch / progress / persist / no-match /
/// never-re-query), promotion linking by external id, and the "From the vault" pool over both
/// sources. All in-memory; no network.
@Suite(.serialized) struct VaultStoreTests {

    private func psn(_ ext: String, _ name: String, platform: String = "ps5",
                     cover: String? = nil, membership: String? = "ps_plus") -> RomCatalogEntry {
        RomCatalogEntry.makePSNVault(externalID: ext, platform: platform, name: name,
                                     coverURL: cover, membership: membership)
    }

    @Test func psnUpsertAndRemoval() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)

        let a = psn("ent:1", "Bloodborne")
        let b = psn("ent:2", "Returnal")
        var c = try await store.syncPSNVault(entries: [a, b],
                                             presentExternalIDs: ["ent:1", "ent:2"])
        #expect(c.added == 2)
        #expect(try await store.sourceCounts().psn == 2)

        // Re-sync: one refreshed, one claim vanished → removed (not deleted).
        c = try await store.syncPSNVault(entries: [psn("ent:1", "Bloodborne GOTY")],
                                         presentExternalIDs: ["ent:1"])
        #expect(c.updated == 1)
        #expect(c.removed == 1)
        #expect(try await store.sourceCounts().psn == 1)
        let present = try await store.sourceCounts()
        #expect(present.batocera == 0)          // library/Batocera untouched
    }

    @Test func sourceCountsHideEmptySources() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        var counts = try await store.sourceCounts()
        #expect(counts.nonEmptySources.isEmpty)

        _ = try await store.syncSystem(system: "snes", entries: [
            RomCatalogEntry.make(from: BatoceraGame(system: "snes", relativePath: "./M.zip", name: "Mario"),
                                 platformID: "snes", libretroKey: "mario"),
        ])
        _ = try await store.syncPSNVault(entries: [psn("ent:1", "Bloodborne")],
                                         presentExternalIDs: ["ent:1"])
        counts = try await store.sourceCounts()
        #expect(counts.batocera == 1)
        #expect(counts.psn == 1)
        #expect(counts.nonEmptySources == [.batocera, .psn])
        #expect(counts.total == 2)
    }

    @Test func traitPassBatchPersistAndNeverRequery() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncPSNVault(
            entries: [psn("ent:1", "Bloodborne"), psn("ent:2", "Returnal"), psn("ent:3", "Astro")],
            presentExternalIDs: ["ent:1", "ent:2", "ent:3"])

        // Capped batch.
        let first = try await store.unmatchedPSN(limit: 2)
        #expect(first.count == 2)

        // Persist a match on one, a no-match on another.
        let traits = [GameTrait(kind: .genre, value: "Action RPG"),
                      GameTrait(kind: .developer, value: "FromSoftware")]
        try await store.setVaultMatch(id: first[0].id, igdbID: 7346, traits: traits,
                                      lengthMainSeconds: 36000, lengthCompleteSeconds: 108000,
                                      igdbRating: 88)
        try await store.setVaultNoMatch(id: first[1].id)

        // Neither is offered again; only the untouched third remains.
        let attempted = Set([first[0].name, first[1].name])
        let remaining = try await store.unmatchedPSN(limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first.map { !attempted.contains($0.name) } == true)

        // Progress line + persisted traits.
        let progress = try await store.psnMatchProgress()
        #expect(progress.matched == 1)
        #expect(progress.total == 3)
        let matched = try #require(try await store.entry(id: first[0].id))
        #expect(matched.igdbID == 7346)
        #expect(matched.matchState == .matched)
        #expect(matched.lengthMainSeconds == 36000)
        #expect(matched.traits.contains(GameTrait(kind: .developer, value: "FromSoftware")))
        #expect(matched.isSuggestable)
    }

    @Test func vaultPoolMixesSourcesAndExcludesUnmatchedPSN() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // A never-played Batocera ROM.
        _ = try await store.syncSystem(system: "snes", entries: [
            RomCatalogEntry.make(from: BatoceraGame(system: "snes", relativePath: "./M.zip",
                                                    name: "Super Metroid", genre: "Action"),
                                 platformID: "snes", libretroKey: "supermetroid"),
        ])
        // Two PS Plus entries: one matched (suggestable), one not.
        _ = try await store.syncPSNVault(entries: [psn("ent:1", "Bloodborne"), psn("ent:2", "Returnal")],
                                         presentExternalIDs: ["ent:1", "ent:2"])
        let unmatched = try await store.unmatchedPSN(limit: 10)
        let bb = try #require(unmatched.first { $0.name == "Bloodborne" })
        try await store.setVaultMatch(id: bb.id, igdbID: 7346,
                                      traits: [GameTrait(kind: .genre, value: "Action RPG")],
                                      lengthMainSeconds: 36000, lengthCompleteSeconds: nil,
                                      igdbRating: 88)

        let pool = try await store.vaultPool()
        let names = Set(pool.map(\.name))
        #expect(names.contains("Super Metroid"))    // Batocera never-played
        #expect(names.contains("Bloodborne"))       // matched PS Plus
        #expect(!names.contains("Returnal"))        // unmatched PS Plus excluded
    }

    @Test func vaultPoolRespectsSkipList() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncSystem(system: "mame", entries: [
            RomCatalogEntry.make(from: BatoceraGame(system: "mame", relativePath: "./x.zip", name: "Arcade"),
                                 platformID: nil, libretroKey: "arcade"),
        ])
        let pool = try await store.vaultPool(skipSystems: ["mame"])
        #expect(pool.isEmpty)
    }

    @Test func promotionLinkByExternalIDLeavesPool() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        _ = try await store.syncPSNVault(entries: [psn("ent:1", "Bloodborne")],
                                         presentExternalIDs: ["ent:1"])
        let bb = try #require(try await store.unmatchedPSN(limit: 1).first)
        try await store.setVaultMatch(id: bb.id, igdbID: 7346, traits: [], lengthMainSeconds: 3600,
                                      lengthCompleteSeconds: nil, igdbRating: nil)
        // Create a library game and link the vault row to it.
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, played) VALUES (55, 'Bloodborne', 1)")
        }
        try await store.setPromotedByExternalID(source: "psn", externalID: "ent:1", gameID: 55)
        let pool = try await store.vaultPool()
        #expect(!pool.contains { $0.name == "Bloodborne" })     // promoted → out of pool
        let linked = try #require(try await store.entry(id: bb.id))
        #expect(linked.promotedGameID == 55)
    }
}
