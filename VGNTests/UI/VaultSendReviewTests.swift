import Foundation
import GRDB
import Testing
@testable import VGN

/// "Send to the Vault" — the fourth fate of a review row (PLAN §16, wave 16). The per-row /
/// group action moves a row out of the importable buckets into a persisted Vault entry
/// (`owned = 1` for a real purchase, a PS Plus claim keeps its subscription), the decision
/// survives a second sync, "Bring back" and Undo reverse it, and the Discover scorer suggests
/// GOG / Delicious vault entries without a PS Plus term. No network.
@MainActor
@Suite(.serialized)
struct VaultSendReviewTests {

    /// Counts `onLibraryChanged` calls — the model fires it once a vault send / bring-back /
    /// undo finishes its DB work, so the DB assertions run only after the write completed.
    private final class ChangeCounter { var n = 0 }

    private func match(_ igdbID: Int64, _ name: String, score: Double = 0.97,
                       slugs: [String] = ["pc"]) -> ScanMatch {
        ScanMatch(igdbID: igdbID, name: name, releaseYear: 2019, coverImageID: "c\(igdbID)",
                  platformSlugs: slugs, score: score, matchedName: name)
    }

    /// A GOG staging store + a matching sync result (two matched rows).
    private func seedGOG() async throws -> (AppDatabase, ImportStagingStore, ImportSyncResult) {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let rows = [
            ImportStagingRow(source: "gog", externalID: "10", name: "The Witcher", platform: "pc"),
            ImportStagingRow(source: "gog", externalID: "20", name: "Stardew Valley", platform: "pc"),
        ]
        try await staging.upsert(rows)
        let matches = [
            ImportMatchResult(externalID: "10", name: "The Witcher",
                              outcome: ScanMatchOutcome(best: match(101, "The Witcher"),
                                                        alternatives: [], bucket: .confident)),
            ImportMatchResult(externalID: "20", name: "Stardew Valley",
                              outcome: ScanMatchOutcome(best: match(201, "Stardew Valley"),
                                                        alternatives: [], bucket: .confident)),
        ]
        let summary = ImportSyncSummary(source: "gog", stagedTotal: 2, newCount: 2)
        return (db, staging, ImportSyncResult(summary: summary, matches: matches, rows: rows))
    }

    private func vaultRow(_ db: AppDatabase, source: String, externalID: String) async throws
        -> (owned: Bool, membership: String?, igdbID: Int64?)? {
        try await db.dbWriter.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT owned, membership, igdb_id FROM rom_catalog
                WHERE source = ? AND relative_path = ?
                """, arguments: [source, externalID]) else { return nil }
            return ((row["owned"] as Int64) != 0, row["membership"], row["igdb_id"])
        }
    }

    // MARK: - Per-row send + persistence

    @Test(.timeLimit(.minutes(1)))
    func sendToVaultWritesOwnedEntryAndPersistsDecision() async throws {
        let (db, staging, result) = try await seedGOG()
        let counter = ChangeCounter()
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                  result: result, onLibraryChanged: { counter.n += 1 })
        await m.load()
        #expect(m.rows(in: .new).count == 2)

        m.sendToVault("10")
        await waitFor { counter.n >= 1 }

        // Leaves the importable buckets, lands in the Vault group.
        #expect(m.rows.first { $0.externalID == "10" }?.vaulted == true)
        #expect(m.rows(in: .new).count == 1)
        #expect(m.vaultedRows.map(\.externalID) == ["10"])

        // A real GOG purchase is written owned, with its IGDB id.
        let entry = try #require(try await vaultRow(db, source: "gog", externalID: "10"))
        #expect(entry.owned == true)
        #expect(entry.membership == nil)
        #expect(entry.igdbID == 101)
        #expect(try await RomCatalogStore(db).sourceCounts().gog == 1)

        // The decision is persisted (`vaulted = 1`) and survives a re-sync (a second model over
        // the same staging shows the row already vaulted, out of New).
        try await staging.upsert(result.rows)   // simulate the next sync's upsert
        let m2 = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging, result: result)
        await m2.load()
        #expect(m2.rows.first { $0.externalID == "10" }?.vaulted == true)
        #expect(m2.rows(in: .new).count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func bringBackReversesTheSend() async throws {
        let (db, staging, result) = try await seedGOG()
        let counter = ChangeCounter()
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                  result: result, onLibraryChanged: { counter.n += 1 })
        await m.load()
        m.sendToVault("10")
        await waitFor { counter.n >= 1 }
        #expect(try await RomCatalogStore(db).sourceCounts().gog == 1)

        m.bringBack("10")
        await waitFor { counter.n >= 2 }
        #expect(m.rows.first { $0.externalID == "10" }?.vaulted == false)
        #expect(try await RomCatalogStore(db).sourceCounts().gog == 0)
        #expect(m.rows(in: .new).count == 2)

        // The persisted decision is cleared, too.
        let titles = try await staging.titles(source: "gog")
        #expect(titles.first { $0.externalID == "10" }?.vaulted == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoLastVaultSendReverses() async throws {
        let (db, staging, result) = try await seedGOG()
        let counter = ChangeCounter()
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                  result: result, onLibraryChanged: { counter.n += 1 })
        await m.load()
        m.sendBucketToVault(.new)                       // group send (both rows)
        await waitFor { counter.n >= 1 }
        #expect(m.vaultedRows.count == 2)
        #expect(try await RomCatalogStore(db).sourceCounts().gog == 2)
        #expect(m.canUndoVaultSend)

        m.undoLastVaultSend()
        await waitFor { counter.n >= 2 }
        #expect(m.vaultedRows.isEmpty)
        #expect(try await RomCatalogStore(db).sourceCounts().gog == 0)
        #expect(!m.canUndoVaultSend)
    }

    // MARK: - Owned-flag rules per source / membership

    @Test(.timeLimit(.minutes(1)))
    func psPlusClaimSentByHandKeepsSubscription() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        // ImportTestDB seeds only pc/mac; platform_id has a platforms FK, so use a seeded slug.
        // The owned/subscription rule under test is platform-agnostic.
        let rows = [ImportStagingRow(source: "psn", externalID: "ent:1", name: "Free Game",
                                     platform: "pc", signals: [.owned],
                                     subscription: .psPlus)]
        try await staging.upsert(rows)
        let matches = [ImportMatchResult(externalID: "ent:1", name: "Free Game",
                                         outcome: ScanMatchOutcome(best: match(9, "Free Game", slugs: ["pc"]),
                                                                   alternatives: [], bucket: .confident))]
        let result = ImportSyncResult(summary: ImportSyncSummary(source: "psn"), matches: matches, rows: rows)
        let counter = ChangeCounter()
        let m = ImportReviewModel(source: "psn", sourceLabel: "PlayStation", staging: staging,
                                  result: result, onLibraryChanged: { counter.n += 1 })
        await m.load()

        m.sendToVault("ent:1")
        await waitFor { counter.n >= 1 }
        let entry = try #require(try await vaultRow(db, source: "psn", externalID: "ent:1"))
        #expect(entry.owned == false)                 // a PS Plus claim keeps its subscription
        #expect(entry.membership == ProductSubscription.psPlus.rawValue)
    }

    // MARK: - Discover scoring over all sources

    @Test func discoverScoresGOGAndDeliciousWithoutPSPlusTerm() {
        var ranked: [RankedGame] = []
        for i in 0..<12 {
            ranked.append(RankedGame(id: Int64(i + 1), igdbID: nil, score: 0.8,
                                     traits: [GameTrait(kind: .genre, value: "Role-playing (RPG)")]))
        }
        let traitsJSON = RomCatalogEntry.encodeTraits([GameTrait(kind: .genre, value: "Role-playing (RPG)")])
        let gog = RomCatalogEntry(id: 1, source: "gog", system: "pc", platformID: "pc",
                                  relativePath: "10", name: "GOG RPG", genre: "Role Playing Game",
                                  externalIDColumn: "10", igdbID: 101, owned: true)
        let delicious = RomCatalogEntry(id: 2, source: "delicious", system: "ps3", platformID: "ps3",
                                        relativePath: "u1", name: "Disc RPG", genre: "Role Playing Game",
                                        externalIDColumn: "u1", igdbID: 202, owned: true)
        let psPlus = RomCatalogEntry(id: 3, source: "psn", system: "ps5", platformID: "ps5",
                                     relativePath: "ent:1", name: "Plus RPG",
                                     externalIDColumn: "ent:1", membership: "ps_plus", igdbID: 303,
                                     traitsJSON: traitsJSON, matchState: .matched, owned: false)

        let scored = DiscoverScorer.score(entries: [gog, delicious, psPlus], ranked: ranked,
                                          options: .init(prioritisePSPlus: true))
        let ids = Set(scored.map(\.entry.id))
        #expect(ids.contains(1) && ids.contains(2) && ids.contains(3))

        func hasSubscriptionReason(_ id: Int64) -> Bool {
            scored.first { $0.entry.id == id }?.reasons.contains {
                if case .leavesWithSubscription = $0 { return true }
                return false
            } ?? false
        }
        #expect(!hasSubscriptionReason(1))   // GOG owned → no PS Plus term
        #expect(!hasSubscriptionReason(2))   // Delicious owned → no PS Plus term
        #expect(hasSubscriptionReason(3))    // a real PS Plus claim → the term applies
    }

    @Test func sidebarRowsAppearOnlyWithCount() {
        var counts = VaultSourceCounts()
        counts.gog = 3
        counts.delicious = 0
        counts.psn = 1
        let sources = counts.nonEmptySources
        #expect(sources.contains(.gog))
        #expect(sources.contains(.psn))
        #expect(!sources.contains(.delicious))
        #expect(!sources.contains(.batocera))
    }
}
