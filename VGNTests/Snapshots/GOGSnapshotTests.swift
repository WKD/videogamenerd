#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// GOG import (PLAN §14): the signed-out and signed-in Settings panes, the review sheet
/// with all three buckets, and a stopped-sync error state. Light + dark. Off by default
/// (like every snapshot suite); references are added, never re-recorded.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
struct GOGSnapshotTests {
    private let group = "14 GOG Import"

    @Test func accountSignedOut() async {
        let model = GOGAccountModel.preview(signedIn: false)
        await model.refresh()
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: group, "gog-account-signed-out",
                                      size: SnapSize(width: 460, height: 300)) {
            GOGAccountPane(model: model).padding()
        }
    }

    @Test func accountSignedIn() async {
        let model = GOGAccountModel.preview(signedIn: true)
        await model.refresh()
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: group, "gog-account-signed-in",
                                      size: SnapSize(width: 460, height: 360)) {
            GOGAccountPane(model: model).padding()
        }
    }

    @Test func accountRejectError() async {
        let reject = ImportReject(
            source: "gog", endpoint: "account/getFilteredProducts", status: 403,
            reason: .loginPageOrHTML, redactedExcerpt: "<html><body>Sign in to continue…</body></html>")
        let surface = ImportErrorSurface.make(from: ImportError.rejected(reject), sourceLabel: "GOG")
        let model = GOGAccountModel.preview(signedIn: true, error: surface)
        await model.refresh()
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: group, "gog-account-reject",
                                      size: SnapSize(width: 460, height: 440)) {
            GOGAccountPane(model: model).padding()
        }
    }

    @Test func reviewSheet() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let rows = [
            ImportStagingRow(source: "gog", externalID: "10", name: "Baldur's Gate",
                             platform: "mac", releaseYear: 1998, macAvailable: true),
            ImportStagingRow(source: "gog", externalID: "20", name: "Penguin Quest",
                             platform: "pc", macAvailable: false, linuxOnly: true),
            ImportStagingRow(source: "gog", externalID: "30", name: "Great OST",
                             platform: "pc", ignoreReason: .soundtrackOrGoodies),
        ]
        try? await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: "gog", fromCache: 4, fromNetwork: 3,
                                       stagedTotal: 3, newCount: 2, ignoredCount: 1, ownedGap: 1),
            matches: [ImportMatchResult(externalID: "10", name: "Baldur's Gate",
                outcome: ScanMatchOutcome(
                    best: ScanMatch(igdbID: 101, name: "Baldur's Gate", releaseYear: 1998,
                                    coverImageID: nil, platformSlugs: ["pc", "mac"], score: 0.97,
                                    matchedName: "Baldur's Gate"),
                    alternatives: [], bucket: .confident))],
            rows: rows)
        let model = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging, result: result)
        await model.load()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "gog-review", size: SnapSize(width: 720, height: 560)) {
            ImportReviewSheet(model: model)
        }
    }
}
#endif
