import Foundation
import Testing
@testable import VGN

/// The PSN-specific review grouping (PLAN §13.3, additive to the shared sheet): bucketing
/// into Played / Launched 0 % / Played — no purchase found / Purchased / PS Plus / Already
/// in your library / Ignored, the "own the ticked rows as ▸ …" group action, the per-row
/// change description, the banner, and the proposed-removals path. GOG/Delicious are
/// untouched (they never enter `isPSN`). All over an in-memory DB — no network.
@MainActor
@Suite(.serialized)
struct PSNReviewGroupingTests {
    private let last = Date(timeIntervalSince1970: 1_650_000_000)   // 2022

    /// Build a model over a set of staged PSN rows, plus an optional already-matched row and
    /// an optional committed-but-disappeared PS Plus copy (for removals).
    private func makeModel(extraMatchedGameID: Int64? = nil,
                           seedDisappearedPlus: Bool = false) async throws -> (ImportReviewModel, ImportStagingStore, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        var rows: [ImportStagingRow] = [
            ImportStagingRow(source: ImportSourceID.psn, externalID: "playedOwned", name: "Elden Ring",
                             platform: "ps5", signals: [.owned, .played], playDurationS: 7200, lastPlayedAt: last),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "launched", name: "Demo Land",
                             platform: "ps4", signals: [.played], launchedNotPlayed: true),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "playedOnly", name: "Bloodborne",
                             platform: "ps4", signals: [.played], playDurationS: 3600, lastPlayedAt: last),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "buy", name: "Stray",
                             platform: "ps5", signals: [.owned]),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "plus", name: "Fall Guys",
                             platform: "ps5", signals: [.owned], subscription: .psPlus),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "noise", name: "Netflix",
                             platform: "ps5", signals: [.owned], ignoreReason: .mediaApp),
        ]
        var matchedRow: ImportStagingRow?
        if extraMatchedGameID != nil {
            matchedRow = ImportStagingRow(source: ImportSourceID.psn, externalID: "matched", name: "Ghost of Tsushima",
                                          platform: "ps5", signals: [.played], playDurationS: 5400, lastPlayedAt: last)
            rows.append(matchedRow!)
        }
        try await staging.upsert(rows)
        if let gid = extraMatchedGameID {
            // Ensure a game row exists so the match is valid, then record the decision.
            try await db.dbWriter.write { db in
                try db.execute(sql: "INSERT OR IGNORE INTO games (id, title, sort_title, played) VALUES (?, 'Ghost of Tsushima', 'ghost of tsushima', 1)",
                               arguments: [gid])
            }
            try await staging.setDecision(source: ImportSourceID.psn, externalID: "matched", .match(gameID: gid))
        }
        if seedDisappearedPlus {
            try await db.dbWriter.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                    VALUES ('ps5', 'PlayStation 5', 'PS5', 'Sony', 'PlayStation', 'console', 500)
                    """)
                try db.execute(sql: "INSERT INTO games (id, title, sort_title, played) VALUES (900, 'Gone Plus', 'gone plus', 0)")
                try db.execute(sql: "INSERT INTO products (id, platform_id, kind, format, source, external_id, subscription) VALUES (910, 'ps5', 'single', 'digital', 'psn', 'gonePlus', 'ps_plus')")
                try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (910, 900, 0)")
            }
        }
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: rows)
        let model = ImportReviewModel(
            source: ImportSourceID.psn, sourceLabel: "PlayStation", staging: staging,
            result: result, productFormat: .digital, platformChoices: PSNImportPresenter.platformChoices)
        await model.load()
        return (model, staging, db)
    }

    private func row(_ model: ImportReviewModel, _ externalID: String) -> ImportReviewRow {
        model.rows.first { $0.externalID == externalID }!
    }

    @Test(.timeLimit(.minutes(1)))
    func rowsBucketIntoTheRightPSNGroups() async throws {
        let (model, _, _) = try await makeModel(extraMatchedGameID: 42)
        #expect(model.psnGroup(for: row(model, "playedOwned")) == .played)
        #expect(model.psnGroup(for: row(model, "launched")) == .launched)
        #expect(model.psnGroup(for: row(model, "playedOnly")) == .playedNoPurchase)
        #expect(model.psnGroup(for: row(model, "buy")) == .purchased)
        #expect(model.psnGroup(for: row(model, "plus")) == .psPlus)
        #expect(model.psnGroup(for: row(model, "matched")) == .alreadyInLibrary)
        #expect(model.psnGroup(for: row(model, "noise")) == .ignored)
    }

    @Test(.timeLimit(.minutes(1)))
    func launchedIsUntickedEverythingElseTicked() async throws {
        let (model, _, _) = try await makeModel()
        #expect(row(model, "launched").include == false)
        #expect(row(model, "playedOwned").include)
        #expect(row(model, "playedOnly").include)
        #expect(row(model, "buy").include)
        #expect(row(model, "plus").include)
    }

    @Test(.timeLimit(.minutes(1)))
    func ownTickedAsForcesAnOwnedCopyOnPlayedOnlyRows() async throws {
        let (model, _, _) = try await makeModel()
        #expect(model.canOwnPlayedRows)   // playedOnly is ticked
        model.ownTickedAs(.physical)
        let items = model.commitItems()
        let playedOnly = try #require(items.first { $0.externalID == "playedOnly" })
        #expect(playedOnly.format == .physical)
        #expect(playedOnly.psn?.createProduct == true)
        #expect(playedOnly.psn?.markPlayed == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func alreadyInLibraryRowDescribesWhatWillChange() async throws {
        let (model, _, _) = try await makeModel(extraMatchedGameID: 42)
        let desc = model.psnChangeDescription(for: row(model, "matched"))
        #expect(desc.contains("+ played"))
        #expect(desc.contains("+ 1 h"))            // 5400 s → 1 h
        #expect(desc.contains("+ last played 2022"))
    }

    @Test(.timeLimit(.minutes(1)))
    func bannerReportsImportedAndUpdatedCounts() async throws {
        let (model, _, _) = try await makeModel(extraMatchedGameID: 42)
        // Ticked: playedOwned, playedOnly, buy, plus, matched (5); launched + noise not.
        let banner = model.psnSuccessMessage()
        #expect(banner.contains("4 games imported from PlayStation"))
        #expect(banner.contains("· 1 updated"))
    }

    @Test(.timeLimit(.minutes(1)))
    func proposedRemovalsSurfaceAndApply() async throws {
        let (model, staging, db) = try await makeModel(seedDisappearedPlus: true)
        #expect(model.proposedRemovals.count == 1)
        let proposal = try #require(model.proposedRemovals.first)
        #expect(proposal.externalID == "gonePlus")
        #expect(proposal.gameTitle == "Gone Plus")

        model.toggleRemoval(proposal.productID, true)
        #expect(model.tickedRemovalCount == 1)
        model.confirmApplyRemovals()
        await poll(until: { model.proposedRemovals.isEmpty })

        // The product (and its never-played game) is gone.
        let (products, games) = try await db.dbWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE id = 910") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE id = 900") ?? -1)
        }
        #expect(products == 0)
        #expect(games == 0)
        _ = staging
    }
}
