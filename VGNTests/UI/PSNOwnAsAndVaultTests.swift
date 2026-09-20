import Foundation
import Testing
import GRDB
@testable import VGN

/// The "Own the ticked rows as" segmented control (PLAN §13.3 / D5): a real toggle bound to
/// model state — applies to ticked rows, adopted by rows ticked afterwards, neutral/mixed look.
@MainActor
@Suite(.serialized)
struct PSNOwnAsControlTests {
    private func model() async throws -> ImportReviewModel {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        // Two played, no-purchase rows (played > 10 min so they are Played — no purchase, not Launched).
        let rows = [
            ImportStagingRow(source: ImportSourceID.psn, externalID: "a", name: "Elden Ring",
                             platform: "ps5", signals: [.played], playDurationS: 3600),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "b", name: "FF VII Rebirth",
                             platform: "ps5", signals: [.played], playDurationS: 7200),
        ]
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: rows)
        let m = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                  staging: staging, result: result, productFormat: .digital,
                                  platformChoices: PSNImportPresenter.platformChoices)
        await m.load()
        return m
    }

    @Test(.timeLimit(.minutes(1)))
    func defaultIsPlayedNotOwned() async throws {
        let m = try await model()
        // Played-no-purchase rows are pre-ticked, but own-as defaults to played-only (neutral).
        #expect(m.canOwnPlayedRows)
        #expect(m.ownAsSelection == nil)
        let items = m.commitItems()
        #expect(items.allSatisfy { $0.psn?.createProduct == false })   // played, not owned
    }

    @Test(.timeLimit(.minutes(1)))
    func pickingAppliesToEveryTickedRow() async throws {
        let m = try await model()
        m.ownAsSelection = .physical
        #expect(m.ownAsSelection == .physical)
        let items = m.commitItems()
        #expect(items.allSatisfy { $0.psn?.createProduct == true })
        #expect(items.allSatisfy { $0.format == .physical })
    }

    @Test(.timeLimit(.minutes(1)))
    func rowsTickedAfterwardsAdoptTheChoice() async throws {
        let m = try await model()
        m.ownAsSelection = .digital                 // session choice = digital
        m.setInclude(false, externalID: "b")        // untick b
        m.setInclude(true, externalID: "b")         // re-tick → adopts digital
        let b = try #require(m.commitItems().first { $0.externalID == "b" })
        #expect(b.format == .digital)
        #expect(b.psn?.createProduct == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func perRowOverrideShowsMixed() async throws {
        let m = try await model()
        m.ownAsSelection = .physical                 // both physical
        #expect(m.ownAsSelection == .physical)
        m.setRowOwnAs(.digital, externalID: "a")     // one differs
        #expect(m.ownAsSelection == nil)             // neutral / mixed look
    }

    /// The owner's bug (2026-09-20): with NO row of the group ticked, picking a segment used to
    /// snap back to neutral (the getter read only the ticked rows and ignored the remembered
    /// session choice). Picking Digital must stick, and a row ticked afterwards adopts it.
    @Test(.timeLimit(.minutes(1)))
    func pickingWithNoTickedRowsIsRemembered() async throws {
        let m = try await model()
        m.setInclude(false, externalID: "a")
        m.setInclude(false, externalID: "b")         // untick every played-no-purchase row
        #expect(!m.canOwnPlayedRows)
        m.ownAsSelection = .digital                  // pick with nothing ticked
        #expect(m.ownAsSelection == .digital)        // sticks (was nil before the fix)
        m.setInclude(true, externalID: "a")          // a row ticked afterwards adopts it
        #expect(m.commitItems().first { $0.externalID == "a" }?.format == .digital)
    }

    /// The three-segment control (Not owned | Physical | Digital) lets the owner return to
    /// "played, not owned" after choosing a format — there is no dead neutral to fall into.
    @Test(.timeLimit(.minutes(1)))
    func canReturnToNotOwned() async throws {
        let m = try await model()
        m.ownAsChoice = .physical
        #expect(m.ownAsChoice == .physical)
        m.ownAsChoice = .notOwned
        #expect(m.ownAsChoice == .notOwned)
        #expect(m.ownAsSelection == nil)
        #expect(m.commitItems().allSatisfy { $0.psn?.createProduct == false })
    }

    /// Choosing a segment after a per-row override re-unifies the group.
    @Test(.timeLimit(.minutes(1)))
    func choosingASegmentReUnifiesAfterMixed() async throws {
        let m = try await model()
        m.ownAsSelection = .physical
        m.setRowOwnAs(.digital, externalID: "a")     // mixed
        #expect(m.ownAsChoice == nil)                // mixed reads as no segment
        m.ownAsChoice = .physical                    // choose again → re-unifies
        #expect(m.ownAsSelection == .physical)
        #expect(m.commitItems().allSatisfy { $0.format == .physical })
    }
}

/// The PSN "Launched" group sends its unticked rows to the Vault at commit (PLAN §16 / D6).
@MainActor
@Suite(.serialized)
struct PSNLaunchedVaultTests {
    private func makeModel(_ db: AppDatabase) async throws -> ImportReviewModel {
        _ = try await db.seedPlatformsFromBundle(.main)   // commit inserts products on ps4/ps5
        let staging = ImportStagingStore(db)
        let rows = [
            // Trophy title at 0 % — merely launched.
            ImportStagingRow(source: ImportSourceID.psn, externalID: "trophy0", name: "Demo Land",
                             platform: "ps4", signals: [.played], launchedNotPlayed: true),
            // Prey: played but barely (8 min 32 s ≤ 10-min gate) — widened Launched (PLAN §16).
            ImportStagingRow(source: ImportSourceID.psn, externalID: "prey", name: "Prey",
                             platform: "ps4", signals: [.played], playDurationS: 512),
            // A real play session — Played, no purchase (stays out of the Launched group).
            ImportStagingRow(source: ImportSourceID.psn, externalID: "real", name: "Bloodborne",
                             platform: "ps4", signals: [.played], playDurationS: 3600),
            // A purchase — owned, never vaulted by low playtime.
            ImportStagingRow(source: ImportSourceID.psn, externalID: "buy", name: "Stray",
                             platform: "ps5", signals: [.owned]),
        ]
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: rows)
        let m = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                  staging: staging, result: result, productFormat: .digital,
                                  platformChoices: PSNImportPresenter.platformChoices)
        await m.load()
        return m
    }

    private func waitForCommit(_ m: ImportReviewModel) async throws {
        for _ in 0..<200 {
            if m.committed || m.commitError != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("commit did not finish in time")
    }

    @Test(.timeLimit(.minutes(1)))
    func launchedGroupWidenedByPlaytimeGate() async throws {
        let m = try await makeModel(try AppDatabase.inMemory())
        // Both the 0 % trophy title and the barely-played Prey land in Launched, unticked.
        #expect(m.psnGroup(for: try #require(m.rows.first { $0.externalID == "trophy0" })) == .launched)
        #expect(m.psnGroup(for: try #require(m.rows.first { $0.externalID == "prey" })) == .launched)
        #expect(m.psnGroup(for: try #require(m.rows.first { $0.externalID == "real" })) == .playedNoPurchase)
        #expect(m.psnGroup(for: try #require(m.rows.first { $0.externalID == "buy" })) == .purchased)
        #expect(Set(m.launchedRowsForVault.map(\.externalID)) == ["trophy0", "prey"])
        #expect(m.launchedVaultCount == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func switchOffAndIgnoreAndTickExcludeFromVault() async throws {
        let m = try await makeModel(try AppDatabase.inMemory())
        m.sendLaunchedToVault = false
        #expect(m.launchedRowsForVault.isEmpty)
        m.sendLaunchedToVault = true
        m.ignore("trophy0")                            // ignored ⇒ not vaulted
        m.setInclude(true, externalID: "prey")         // ticked ⇒ imports normally, not vaulted
        #expect(m.launchedRowsForVault.isEmpty)
        #expect(m.rows.first { $0.externalID == "prey" }?.isCommittable == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func commitVaultsUntickedLaunchedRowsOwnedAndBannerReports() async throws {
        let db = try AppDatabase.inMemory()
        let m = try await makeModel(db)
        let vaultStore = RomCatalogStore(db)
        #expect(try await vaultStore.totalCount() == 0)

        m.commit()
        try await waitForCommit(m)
        #expect(m.commitError == nil)

        // The two Launched rows went to the Vault; the banner names both counts.
        #expect(try await vaultStore.totalCount() == 2)
        #expect(m.rows.first { $0.externalID == "trophy0" }?.vaulted == true)
        #expect(m.rows.first { $0.externalID == "prey" }?.vaulted == true)
        let banner = try #require(m.successMessage)
        #expect(banner.contains("2 sent to the Vault"))

        // A played-not-owned launched row is vaulted as OWNED (owned = 1), not a subscription claim.
        let owned = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT owned FROM rom_catalog WHERE source = 'psn' AND relative_path = ?",
                             arguments: ["prey"])
        }
        #expect(owned == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func switchOffCommitVaultsNothing() async throws {
        let db = try AppDatabase.inMemory()
        let m = try await makeModel(db)
        m.sendLaunchedToVault = false
        m.commit()
        try await waitForCommit(m)
        #expect(try await RomCatalogStore(db).totalCount() == 0)
        #expect(m.successMessage?.contains("sent to the Vault") != true)
    }

    @Test(.timeLimit(.minutes(1)))
    func undoReversesTheVaultSend() async throws {
        let db = try AppDatabase.inMemory()
        let m = try await makeModel(db)
        m.commit()
        try await waitForCommit(m)
        #expect(try await RomCatalogStore(db).totalCount() == 2)
        #expect(m.canUndoVaultSend)

        // UndoManager.undo() hangs headless — drive the inverse directly (CLAUDE.md).
        m.undoLastVaultSend()
        for _ in 0..<200 where (try? await RomCatalogStore(db).totalCount()) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await RomCatalogStore(db).totalCount() == 0)
        #expect(m.rows.first { $0.externalID == "prey" }?.vaulted == false)
    }
}
