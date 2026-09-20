import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks (headless, off-screen, toolbar-shaped window) against the new Batocera
/// main-window primary buttons — the ROM Catalogue's **Add to Library…** and **Not Interested**
/// (which sit directly under the unified toolbar, where the 2026-09-19 dead-click bug bit) and
/// the review banner's **Review…** — so a dead-click fails a test (PLAN §15). A bounded
/// single-pass grid keeps each test to a few seconds.
///
/// (Settings ▸ Batocera's **Sync Now** lives in the Settings window, not under the main
/// toolbar, so it carries no dead-click risk; its click path is covered by
/// `BatoceraSettingsModelTests.syncNowRunsAndReportsCandidatesThroughTheBannerCallback`.)
@MainActor
@Suite(.serialized)
struct BatoceraClickProbeTests {

    private func recordingEnv(addLog: @escaping @MainActor ([Int64]) -> Void) -> BatoceraEnvironment {
        let store = RomCatalogStore(try! AppDatabase.inMemory())
        return BatoceraEnvironment(
            catalog: store, thumbnails: BatoceraThumbnailLoader(romsRoot: nil),
            discover: InertDiscoverBackend(), isLive: false, romsRoot: nil,
            addToLibrary: addLog, inspectGame: nil, showCatalogue: nil)
    }

    private func hosted(_ content: some View) -> ClickProbeWindow {
        ClickProbeWindow(VStack(spacing: 0) { content; Color.clear }
            .frame(minWidth: 820, minHeight: 520)
            .toolbar { Button("x") {} })
    }

    /// Only the RIGHT half of the toolbar band: the action buttons sit right of the Spacer, while
    /// the left half holds the "All Systems" and "Sort" `Menu`s. A synthetic click on a Menu pops
    /// a REAL menu on the owner's screen and blocks the run until it is dismissed (it happened,
    /// 2026-09-19) — never sweep over one. (Every click is pop-up guarded regardless.)
    private func rightHalf(_ w: ClickProbeWindow) -> CGFloat { w.window.frame.width * 0.55 }

    @Test(.timeLimit(.minutes(3)))
    func addToLibraryButtonReceivesClicks() async throws {
        var addCalls = 0
        let env = recordingEnv { _ in addCalls += 1 }
        let model = RomCatalogueModel(catalog: env.catalog)
        model.selection = [1]                       // enables the action buttons
        let window = hosted(RomCatalogueContent(env: env, model: model))
        defer { window.close() }
        try await window.settle()
        #expect(await window.poll { window.hasToolbar })
        let hit = await window.sweepBand(yTop: window.contentTop - 2, yBottom: window.contentTop - 82,
                                         stepX: 11, stepY: 9, xMin: rightHalf(window)) { addCalls > 0 }
        #expect(hit, "the Add to Library… button never received a click")
    }

    @Test(.timeLimit(.minutes(3)))
    func notInterestedButtonReceivesClicks() async throws {
        let env = recordingEnv { _ in }
        let model = RomCatalogueModel(catalog: env.catalog)
        model.selection = [1, 2]
        let window = hosted(RomCatalogueContent(env: env, model: model))
        defer { window.close() }
        try await window.settle()
        // "Not Interested" (rightmost of the two) clears the selection.
        let hit = await window.sweepBand(yTop: window.contentTop - 2, yBottom: window.contentTop - 82,
                                         stepX: 11, stepY: 9, xMin: rightHalf(window),
                                         rightToLeft: true) { model.selection.isEmpty }
        #expect(hit, "the Not Interested button never received a click")
    }

    @Test(.timeLimit(.minutes(3)))
    func reviewBannerActionReceivesClicks() async throws {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        var reviewed = 0
        vm.showBanner("12 Batocera games ready to review", actionTitle: "Review…") { reviewed += 1 }
        let window = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 600))
        defer { window.close() }
        try await window.settle()
        #expect(vm.banner?.actionTitle == "Review…")
        // The banner pins to the bottom of the content, so click a band near the window bottom.
        let hit = await window.sweepBottomBand(height: 100, stepX: 11, stepY: 9) { reviewed > 0 }
        #expect(hit, "the review banner's Review… button never received a click")
    }
}
