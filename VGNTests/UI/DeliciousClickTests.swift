import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks (via ``ClickProbeWindow``) against the one control the Delicious
/// review sheet adds to the shared sheet: the header "Use my … covers" toggle. An empty
/// result ⇒ no rows (no per-row menus to pop up during the coarse sweep).
@MainActor
@Suite(.serialized)
struct DeliciousClickTests {

    @Test(.timeLimit(.minutes(5)))
    func sourceCoverToggleReceivesClicks() async throws {
        let db = try await DeliciousTestDB.makeSeeded()
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: ImportSourceID.delicious, fromFile: 0),
            matches: [], rows: [])
        let model = ImportReviewModel(
            source: ImportSourceID.delicious, sourceLabel: "Delicious Library",
            staging: ImportStagingStore(db), result: result,
            productFormat: .physical, platformChoices: ["ps3", "pc", "mac"],
            detectShelfDuplicates: true, showsSourceCoverToggle: true)
        await model.load()
        #expect(model.useSourceCovers == true)   // defaults ON

        let size = NSSize(width: 660, height: 520)
        let window = ClickProbeWindow(ImportReviewSheet(model: model), size: size)
        defer { window.close() }
        try await window.settle()

        let hits = try await window.sweep(band: size.height, stepX: 18, stepY: 12) {
            model.useSourceCovers ? 0 : 1
        } until: { !model.useSourceCovers }
        #expect(hits >= 1, "the source-cover toggle never received a click")
        #expect(model.useSourceCovers == false)
    }
}
