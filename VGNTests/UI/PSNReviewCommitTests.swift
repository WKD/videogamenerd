import Foundation
import Testing
@testable import VGN

/// The shared review model builds the correct ``PSNCommit`` for PSN rows (PLAN §13.3): a
/// purchase creates an owned digital copy (with any PS Plus flag), a played title marks
/// the game played + records play time / dates / status, and a *launched, 0 %* title is
/// never marked played. GOG/Delicious rows keep `psn == nil`.
@MainActor
@Suite(.serialized)
struct PSNReviewCommitTests {
    private let first = Date(timeIntervalSince1970: 1_600_000_000)
    private let last = Date(timeIntervalSince1970: 1_650_000_000)

    private func model() async throws -> ImportReviewModel {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        let rows = [
            // A played trophy title, not owned.
            ImportStagingRow(source: ImportSourceID.psn, externalID: "played", name: "Bloodborne",
                             platform: "ps4", signals: [.played], playDurationS: 3600,
                             firstPlayedAt: first, lastPlayedAt: last,
                             statusPrefill: .completed),
            // A purchase (owned digital).
            ImportStagingRow(source: ImportSourceID.psn, externalID: "buy", name: "Stray",
                             platform: "ps5", signals: [.owned]),
            // A PS Plus claim (owned via subscription).
            ImportStagingRow(source: ImportSourceID.psn, externalID: "plus", name: "Fall Guys",
                             platform: "ps5", signals: [.owned], subscription: .psPlus),
            // Launched, 0 % — signalled played but merely launched, so NOT played.
            ImportStagingRow(source: ImportSourceID.psn, externalID: "launched", name: "Demo Land",
                             platform: "ps4", signals: [.played], launchedNotPlayed: true),
        ]
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn), matches: [], rows: rows)
        let m = ImportReviewModel(
            source: ImportSourceID.psn, sourceLabel: "PlayStation", staging: staging,
            result: result, productFormat: .digital,
            platformChoices: PSNImportPresenter.platformChoices)
        await m.load()
        // Tick every row (none is pre-ticked without a confident match).
        for id in ["played", "buy", "plus", "launched"] { m.setInclude(true, externalID: id) }
        return m
    }

    @Test(.timeLimit(.minutes(1)))
    func playedTitleCommitsPlayedWithDatesButNoProduct() async throws {
        let items = try await model().commitItems()
        let played = try #require(items.first { $0.externalID == "played" })
        let psn = try #require(played.psn)
        #expect(psn.markPlayed)
        #expect(!psn.createProduct)
        #expect(psn.playDurationS == 3600)
        #expect(psn.firstPlayedAt == first)
        #expect(psn.lastPlayedAt == last)
        #expect(psn.statusPrefill == .completed)
    }

    @Test(.timeLimit(.minutes(1)))
    func purchaseCommitsOwnedCopyNotPlayed() async throws {
        let items = try await model().commitItems()
        let buy = try #require(items.first { $0.externalID == "buy" })
        let psn = try #require(buy.psn)
        #expect(psn.createProduct)
        #expect(!psn.markPlayed)
        #expect(psn.subscription == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func psPlusCommitsSubscriptionFlag() async throws {
        let items = try await model().commitItems()
        let plus = try #require(items.first { $0.externalID == "plus" })
        #expect(plus.psn?.createProduct == true)
        #expect(plus.psn?.subscription == "ps_plus")
    }

    @Test(.timeLimit(.minutes(1)))
    func launchedTitleIsNeverMarkedPlayed() async throws {
        let items = try await model().commitItems()
        let launched = try #require(items.first { $0.externalID == "launched" })
        #expect(launched.psn?.markPlayed == false)
        #expect(launched.psn?.createProduct == false)
    }
}
