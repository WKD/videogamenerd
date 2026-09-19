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

    /// One patient grid pass over a horizontal band measured from the top (`fromTop`) or the
    /// bottom (`!fromTop`) of the window content, stopping as soon as `until` is true.
    private func clickBand(_ w: ClickProbeWindow, top: CGFloat, height: CGFloat,
                           rightToLeft: Bool, until: () -> Bool) async {
        let width = w.window.frame.width
        // ONLY the right half of the band: the action buttons sit right of the Spacer. The
        // left half holds the "All Systems" and "Sort" `Menu`s — a synthetic click on a Menu
        // pops a REAL menu on the owner's screen and blocks the whole test run until someone
        // dismisses it (it happened, 2026-09-19). Never sweep over a Menu / menu-style Picker.
        let xs = Array(stride(from: width * 0.55, through: width - 6, by: 11))
        let ordered = rightToLeft ? xs.reversed() : Array(xs)
        for y in stride(from: top, through: top - height, by: -9) {
            for x in ordered {
                w.click(at: NSPoint(x: x, y: y))
                try? await Task.sleep(for: .milliseconds(25))
                if until() { return }
            }
        }
    }

    @Test(.timeLimit(.minutes(3)))
    func addToLibraryButtonReceivesClicks() async throws {
        var addCalls = 0
        let env = recordingEnv { _ in addCalls += 1 }
        let model = RomCatalogueModel(catalog: env.catalog)
        model.selection = [1]                       // enables the action buttons
        let window = hosted(RomCatalogueContent(env: env, model: model))
        defer { window.close() }
        try await window.settle()
        #expect(window.hasToolbar)
        await clickBand(window, top: window.contentTop - 2, height: 80, rightToLeft: false) { addCalls > 0 }
        #expect(addCalls > 0, "the Add to Library… button never received a click")
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
        await clickBand(window, top: window.contentTop - 2, height: 80, rightToLeft: true) { model.selection.isEmpty }
        #expect(model.selection.isEmpty, "the Not Interested button never received a click")
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
        await clickBand(window, top: 100, height: 92, rightToLeft: false) { reviewed > 0 }
        #expect(reviewed > 0, "the review banner's Review… button never received a click")
    }
}
