import Foundation
import Testing
@testable import VGN

/// The Vault browser's PS Plus side (PLAN §16): the source-aware system labels, "Add to
/// Library…" committing an owned-via-subscription copy through the shared path and linking the
/// Vault row, and the browser model's add + reload. In-memory DB; no network.
@MainActor
@Suite(.serialized)
struct VaultBrowserTests {

    private func psn(_ ext: String, _ name: String, platform: String = "ps5",
                     igdbID: Int64? = nil) -> RomCatalogEntry {
        var e = RomCatalogEntry.makePSNVault(externalID: ext, platform: platform, name: name,
                                             coverURL: "https://example.invalid/\(ext).jpg",
                                             membership: "ps_plus")
        e.igdbID = igdbID
        if igdbID != nil { e.matchState = .matched }
        return e
    }

    private func seed(_ store: RomCatalogStore, _ entries: [RomCatalogEntry]) async throws {
        _ = try await store.syncPSNVault(entries: entries,
                                         presentExternalIDs: Set(entries.map(\.relativePath)))
    }

    @Test func systemLabelsAreSourceAware() {
        let ps = RomCatalogueSystemCount(system: "ps5", count: 3, source: .psn)
        #expect(ps.label == PlatformLabels.short("ps5"))
        #expect(ps.label != "ps5")               // a friendly platform name, not the raw slug
    }

    @Test(.timeLimit(.minutes(1)))
    func addToLibraryCommitsSubscriptionCopyAndLinks() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("ent:1", "Bloodborne", igdbID: 42)])
        let entry = try await store.unmatchedOrMatchedFirst()

        let promoter = VaultLibraryPromoter(staging: ImportStagingStore(db), catalog: store)
        let gameID = try await promoter.addToLibrary(entry)
        #expect(gameID != nil)

        // The Vault row is linked to the created game (promotion bridge / "In Library").
        let linked = try await store.entry(id: entry.id)
        #expect(linked?.promotedGameID == gameID)

        // The library now has exactly one game, owned via a PS Plus subscription copy.
        let (games, subs, title) = try await db.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE subscription = 'ps_plus'") ?? 0,
             try String.fetchOne(db, sql: "SELECT title FROM games LIMIT 1"))
        }
        #expect(games == 1)
        #expect(subs == 1)
        #expect(title == "Bloodborne")
    }

    @Test(.timeLimit(.minutes(1)))
    func browserModelAddsAndReloadsWithInLibraryMarker() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        try await seed(store, [psn("ent:1", "Returnal", igdbID: 99)])

        let model = RomCatalogueModel(catalog: store, source: .psn)
        model.start()
        await pollUntil { model.hasLoaded && !model.entries.isEmpty }
        let id = model.entries.first!.id
        #expect(model.entries.first?.promotedGameID == nil)

        model.addPSPlusToLibrary(ids: [id])
        await pollUntil { model.entries.first?.promotedGameID != nil }
        #expect(model.entries.first?.promotedGameID != nil)
    }

    private func pollUntil(_ cond: () -> Bool) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

private extension RomCatalogStore {
    /// The single seeded PS Plus entry (test convenience).
    func unmatchedOrMatchedFirst() async throws -> RomCatalogEntry {
        try await browse(source: VaultSource.psn.storage, system: nil, filter: .all,
                         sort: .title, search: "", limit: 1, offset: 0).first!
    }
}
