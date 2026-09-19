import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks (via ``ClickProbeWindow``) against the GOG Settings pane's primary
/// button and the import review sheet's footer — model tests cannot see hit-testing bugs,
/// so these confirm the controls actually receive clicks. Both views are kept menu-free
/// (no `Menu` / web view) so a coarse sweep can't open a pop-up in the off-screen window.
@MainActor
@Suite(.serialized)
struct GOGClickTests {

    @Test(.timeLimit(.minutes(5)))
    func settingsPaneSyncNowReceivesClicks() async throws {
        let db = try AppDatabase.inMemory()
        // Empty data sets ⇒ no Force-refresh buttons/dialogs; only the primary actions.
        let backend = FakeImportBackend(dataSets: [], staging: ImportStagingStore(db),
                                        session: true, username: "gog_gamer")
        let model = GOGAccountModel(backend: backend, login: nil)
        await model.refresh()
        var syncs = 0
        model.onSyncRequested = { syncs += 1 }

        let size = NSSize(width: 420, height: 320)
        let window = ClickProbeWindow(
            VStack { GOGAccountPane(model: model); Spacer() }.padding(), size: size)
        defer { window.close() }
        try await window.settle()

        let hits = try await window.sweep(band: size.height, stepX: 20, stepY: 14) { syncs } until: { syncs > 0 }
        #expect(hits >= 1, "Sync Now never received a click")
        #expect(syncs > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func reviewSheetFooterReceivesClicks() async throws {
        let db = try await ImportTestDB.makeSeeded()
        // An empty result ⇒ no rows (so no per-row menus); the footer's Cancel is the
        // control under test.
        let result = ImportSyncResult(summary: ImportSyncSummary(source: "gog"), matches: [], rows: [])
        let model = ImportReviewModel(source: "gog", sourceLabel: "GOG",
                                      staging: ImportStagingStore(db), result: result)
        await model.load()
        var closed = false

        let size = NSSize(width: 660, height: 520)
        let window = ClickProbeWindow(
            ImportReviewSheet(model: model) { closed = true }, size: size)
        defer { window.close() }
        try await window.settle()

        let hits = try await window.sweep(band: size.height, stepX: 20, stepY: 14) {
            closed ? 1 : 0
        } until: { closed }
        #expect(hits >= 1, "the footer Cancel button never received a click")
        #expect(closed)
    }
}
