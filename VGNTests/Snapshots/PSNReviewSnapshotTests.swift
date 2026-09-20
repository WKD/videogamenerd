#if DEBUG
import Foundation
import Testing
@testable import VGN

/// The PSN import review sheet (PLAN §13.3): every group (Played · Launched · Played — no
/// purchase found · Purchased · PS Plus · Already in your library · In the Vault · Ignored),
/// the "own the ticked rows as" segment (neutral + Physical), a bundle row with member
/// played-ticks + a cross-gen twin note, and the empty state. All over an in-memory DB — no
/// network. Off by default like every snapshot suite; references are added, never re-recorded.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: snapshotSuitesEnabled()))
struct PSNReviewSnapshotTests {
    private let group = "13 PSN Import"
    private let last = Date(timeIntervalSince1970: 1_650_000_000)

    /// A model holding one row per PSN group (+ a matched-in-library row and a vaulted row).
    private func groupsModel() async throws -> ImportReviewModel {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        let rows: [ImportStagingRow] = [
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
            ImportStagingRow(source: ImportSourceID.psn, externalID: "matched", name: "Ghost of Tsushima",
                             platform: "ps5", signals: [.played], playDurationS: 5400, lastPlayedAt: last),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "vaulted", name: "Sampled Game",
                             platform: "ps5", signals: [.played], playDurationS: 120),
            ImportStagingRow(source: ImportSourceID.psn, externalID: "noise", name: "Netflix",
                             platform: "ps5", signals: [.owned], ignoreReason: .mediaApp),
        ]
        try await staging.upsert(rows)
        try await db.dbWriter.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO games (id, title, sort_title, played) VALUES (42, 'Ghost of Tsushima', 'ghost of tsushima', 1)")
        }
        try await staging.setDecision(source: ImportSourceID.psn, externalID: "matched", .match(gameID: 42))
        try await staging.setDecision(source: ImportSourceID.psn, externalID: "vaulted", .vault)
        let result = ImportSyncResult(summary: ImportSyncSummary(source: ImportSourceID.psn),
                                      matches: [], rows: rows)
        let model = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                      staging: staging, result: result, productFormat: .digital,
                                      platformChoices: PSNImportPresenter.platformChoices)
        await model.load()
        return model
    }

    @Test func reviewGroups() async throws {
        let model = try await groupsModel()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "psn-review-groups",
                                      size: SnapSize(width: 720, height: 1040)) {
            ImportReviewSheet(model: model)
        }
    }

    // NOTE: the "own the ticked rows as ▸ Physical" *selected* state is deliberately not a
    // snapshot. `ownTickedAs(.physical)` works at the model level (unit-tested in
    // PSNReviewGroupingTests), but the segment's `ownAsSelection` reads back neutral in an
    // off-screen capture, so a Physical-selected shot renders identically to the neutral one in
    // `psn-review-groups` — recording it would be a misleading duplicate. The neutral segment is
    // shown in `psn-review-groups`; the Physical behaviour is covered by the model test.

    @Test func reviewBundleAndTwin() async throws {
        let db = try AppDatabase.inMemory()
        try await db.seedPlatforms(from: [
            .init(id: "ps5", name: "PlayStation 5", short: "PS5", manufacturer: "Sony",
                  group: "Console", kind: "console", generation: 9, igdbIDs: [167], libretroRepo: nil, sort: 1),
            .init(id: "ps4", name: "PlayStation 4", short: "PS4", manufacturer: "Sony",
                  group: "Console", kind: "console", generation: 8, igdbIDs: [48], libretroRepo: nil, sort: 2),
        ])
        let staging = ImportStagingStore(db)
        // A played bundle (asks "which did you play?") + a cross-gen twin pair.
        let bundle = ImportStagingRow(source: ImportSourceID.psn, externalID: "b1",
                                      name: "BioShock: The Collection", platform: "ps4",
                                      signals: [.played], playDurationS: 7200)
        let ps4 = ImportStagingRow(source: ImportSourceID.psn, externalID: "ps4id",
                                   name: "Man of Medan PS4", platform: "ps4", signals: [.owned])
        let ps5 = ImportStagingRow(source: ImportSourceID.psn, externalID: "ps5id",
                                   name: "Man of Medan PS5", platform: "ps5", signals: [.owned])
        try await staging.upsert([bundle, ps4, ps5])
        func twin(_ ext: String, _ platform: String) -> ImportMatchResult {
            ImportMatchResult(externalID: ext, name: "Man of Medan", outcome: ScanMatchOutcome(
                best: ScanMatch(igdbID: 42, name: "Man of Medan", releaseYear: nil, coverImageID: nil,
                                platformSlugs: [platform], score: 0.95, matchedName: "Man of Medan"),
                alternatives: [], bucket: .confident))
        }
        let bundleMatch = ImportMatchResult(externalID: "b1", name: bundle.name, outcome: ScanMatchOutcome(
            best: ScanMatch(igdbID: 900, name: bundle.name, releaseYear: nil, coverImageID: nil,
                            platformSlugs: ["ps4"], score: 0.98, matchedName: bundle.name, gameType: .bundle),
            alternatives: [], bucket: .confident))
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.psn),
            matches: [bundleMatch, twin("ps4id", "ps4"), twin("ps5id", "ps5")],
            rows: [bundle, ps4, ps5],
            bundleExpansions: ["b1": ImportBundleExpansion(bundleIGDBID: 900, title: bundle.name, members: [
                CompilationMemberDraft(title: "BioShock", igdbID: 1, position: 0),
                CompilationMemberDraft(title: "BioShock 2", igdbID: 2, position: 1),
                CompilationMemberDraft(title: "BioShock Infinite", igdbID: 3, position: 2)])])
        let model = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                      staging: staging, result: result, productFormat: .digital,
                                      platformChoices: ["ps5", "ps4"])
        await model.load()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "psn-review-bundle-twin",
                                      size: SnapSize(width: 720, height: 620)) {
            ImportReviewSheet(model: model)
        }
    }

    @Test func reviewEmpty() async throws {
        let db = try AppDatabase.inMemory()
        let result = ImportSyncResult(summary: ImportSyncSummary(source: ImportSourceID.psn),
                                      matches: [], rows: [])
        let model = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                      staging: ImportStagingStore(db), result: result, productFormat: .digital)
        await model.load()
        await SnapshotHarness.capture(group: group, "psn-review-empty",
                                      size: SnapSize(width: 720, height: 460)) {
            ImportReviewSheet(model: model)
        }
    }
}
#endif
