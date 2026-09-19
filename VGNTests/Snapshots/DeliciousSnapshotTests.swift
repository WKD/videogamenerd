#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Delicious Library import (PLAN §5.5): the shared review sheet with Delicious rows —
/// a console game, a matched game with an edition, and a shelf-duplicate. Off by default
/// like every snapshot suite; references are added, never re-recorded.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
struct DeliciousSnapshotTests {
    private let group = "05 Delicious Import"

    @Test func reviewSheet() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let rows = [
            ImportStagingRow(source: ImportSourceID.delicious, externalID: "10",
                             name: "Heavy Rain PS3 - édition spéciale", platform: "ps3",
                             releaseYear: 2010, matchTitle: "Heavy Rain", edition: "Special Edition"),
            ImportStagingRow(source: ImportSourceID.delicious, externalID: "20",
                             name: "Cérébrale Académie", platform: "ds", releaseYear: 2006),
        ]
        try? await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.delicious, stagedTotal: 2,
                                       newCount: 2, fromFile: 2),
            matches: [
                ImportMatchResult(externalID: "10", name: "Heavy Rain",
                    outcome: ScanMatchOutcome(
                        best: ScanMatch(igdbID: 101, name: "Heavy Rain", releaseYear: 2010,
                                        coverImageID: nil, platformSlugs: ["ps3"], score: 0.96,
                                        matchedName: "Heavy Rain"),
                        alternatives: [], bucket: .confident)),
                ImportMatchResult(externalID: "20", name: "Cérébrale Académie",
                    outcome: ScanMatchOutcome(
                        best: ScanMatch(igdbID: 202, name: "Big Brain Academy: Wii Degree",
                                        releaseYear: 2006, coverImageID: nil, platformSlugs: ["ds"],
                                        score: 0.72, matchedName: "Cérébrale Académie"),
                        alternatives: [], bucket: .plausible)),
            ],
            rows: rows)
        let model = ImportReviewModel(
            source: ImportSourceID.delicious, sourceLabel: "Delicious Library", staging: staging,
            result: result, productFormat: .physical,
            platformChoices: ["ps3", "ps2", "ds", "wii", "pc", "mac"],
            detectShelfDuplicates: true, showsSourceCoverToggle: true)
        await model.load()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "delicious-review", size: SnapSize(width: 720, height: 560)) {
            ImportReviewSheet(model: model)
        }
    }
}
#endif
