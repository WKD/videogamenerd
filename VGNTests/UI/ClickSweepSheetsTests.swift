import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Wave-18 click-probe sweep — STATS window and the SHEETS.
///
/// Sheet CHROME can't be rendered off-screen, so each sheet's CONTENT view is hosted directly.
/// Every click is pop-up-guarded, and dangerous controls are avoided by construction (a menu-
/// backed platform `Picker`, or a footer "Choose File…" that opens a native NSOpenPanel). No
/// database (fakes / preview reports / plain value models), no network.
@MainActor
@Suite(.serialized)
struct ClickSweepSheetsTests {

    private func host(_ content: some View, _ size: NSSize) -> ClickProbeWindow {
        ClickProbeWindow(content.frame(width: size.width, height: size.height).toolbar { Button("x") {} },
                         size: size)
    }

    // MARK: - Stats (segmented scope picker + "Show all games")

    @Test(.timeLimit(.minutes(2)))
    func statsScopeSegmentedPickerSwitchesScope() async throws {
        let model = StatsModel(previewReport: .sample)
        let start = model.scope
        let targetIndex = (start == .played) ? 0 : StatsScope.allCases.count - 1
        let target = StatsScope.allCases[targetIndex]

        let window = host(StatsDashboardView(model: model), NSSize(width: 760, height: 520))
        defer { window.close() }
        await window.settleShort()
        #expect(window.hasSegmentedControl(), "Stats scope should be a segmented control, not a menu")

        #expect(await window.clickSegment(targetIndex, of: StatsScope.allCases.count),
                "the Stats scope segmented control was not located")
        let switched = await window.poll { model.scope == target }
        #expect(switched, "clicking the Stats scope segment did not switch the scope")
    }

    @Test(.timeLimit(.minutes(2)))
    func statsEmptyStateShowAllGamesButtonFires() async throws {
        let model = StatsModel(previewReport: .empty(scope: .played))
        #expect(model.report.isEmpty && model.scope != .all)

        let window = host(StatsDashboardView(model: model), NSSize(width: 760, height: 520))
        defer { window.close() }
        await window.settleShort()

        // "Show all games" is centred; sweep the middle (below the header's scope picker) — a
        // click sets the scope to .all.
        let w = window.window.frame.width
        let fired = await window.sweepBand(yTop: window.contentTop - 110, yBottom: 60,
                                           stepX: 20, stepY: 14, xMin: w * 0.28, xMax: w * 0.72,
                                           maxClicks: 600) { model.scope == .all }
        #expect(fired, "the Stats empty-state ‘Show all games’ button never switched to All")
    }

    // MARK: - Choose Cover sheet (tile click selects)

    @Test(.timeLimit(.minutes(2)))
    func chooseCoverTileClickSelects() async throws {
        let candidates = [
            CoverCandidate(providerID: "igdb", remoteURL: URL(string: "https://example.test/a.jpg")!,
                           label: "IGDB", score: 0.92, isConfident: true),
            CoverCandidate(providerID: "libretro", remoteURL: URL(string: "https://example.test/b.jpg")!,
                           label: "Libretro", score: 0.71, isConfident: false),
        ]
        let model = ChooseCoverModel(gameID: 1, title: "Chrono Trigger", currentCoverFile: nil,
                                     backend: FakeChooseCoverBackend(candidates))
        var finished = 0
        model.onFinished = { finished += 1 }
        await model.load()

        // Host as the green sheet-click tests do (sheet centred in the default window). The tile
        // stacks a `count:2` tap (→ `use`) OVER a `count:1` tap (→ select): a rapid single-click
        // sweep never lets the single tap resolve (each is cancelled by the pending double-tap),
        // so DOUBLE-click the grid → `use` fires → `onFinished`, proving the tile is clickable.
        // Sweep only the upper band (the footer's NSOpenPanel "Choose File…" sits far lower and
        // is never reached); early-stopping and pop-up-guarded.
        let window = ClickProbeWindow(ChooseCoverSheet(model: model, loader: NoopCoverLoader())
            .frame(width: 640, height: 560))
        defer { window.close() }
        try await window.settle()
        let hit = await window.sweepTopBand(height: 340, stepX: 22, stepY: 20, maxClicks: 500,
                                            doubleClick: true) { finished > 0 || model.selection != nil }
        #expect(hit, "clicking a Choose Cover candidate tile registered neither a select nor a use")
    }

    // MARK: - Bulk "Mark Owned" sheet (Mark Owned confirm button)

    @Test(.timeLimit(.minutes(2)))
    func bulkMarkOwnedConfirmButtonFires() async throws {
        let games = [
            GameSummary(id: 1, title: "Game One", year: 2018, played: false, owned: false, platformIDs: ["ps5"]),
            GameSummary(id: 2, title: "Game Two", year: 2020, played: false, owned: false, platformIDs: ["ps4"]),
        ]
        final class Box: @unchecked Sendable { var specs: [BatchCopySpec]?; var closed = false }
        let box = Box()
        let model = BatchOwnershipModel(games: games, allPlatforms: PlatformLabels.all,
                                        preferences: InMemoryBatchOwnershipPreferences()) { box.specs = $0 }
        #expect(model.canConfirm)

        let window = host(BatchOwnershipSheet(model: model, onClose: { box.closed = true }),
                          NSSize(width: 460, height: 420))
        defer { window.close() }
        await window.settleShort()

        // Buttons are the bottom row (Cancel · Mark Owned). Sweep the bottom band right→left so
        // the trailing "Mark Owned" is reached before "Cancel"; per-row platform pop-ups sit
        // above and are pop-up-guarded regardless.
        let confirmed = await window.sweepBottomBand(height: 64, rightToLeft: true) { box.specs != nil }
        #expect(confirmed, "the bulk Mark Owned confirm button never received a click")
    }

    // MARK: - Banner secondary action (RootView overlay)

    @Test(.timeLimit(.minutes(3)))
    func bannerSecondaryActionReceivesClicks() async throws {
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource.sampled)
        var secondary = 0
        vm.showBanner("12 Batocera games ready to review", actionTitle: "Undo", action: {},
                      secondaryActionTitle: "Review…", secondaryAction: { secondary += 1 })
        let window = ClickProbeWindow(RootView(vm: vm).frame(minWidth: 900, minHeight: 560),
                                      size: NSSize(width: 900, height: 560))
        defer { window.close() }
        await window.settleShort()
        #expect(vm.banner?.secondaryActionTitle == "Review…")

        // The banner pins to the bottom; its buttons run message · [Review…] · [Undo] · ✕, so a
        // left→right sweep of the bottom band reaches the secondary "Review…" first.
        let fired = await window.sweepBottomBand(height: 110) { secondary > 0 }
        #expect(fired, "the banner's secondary action button never received a click")
    }

    // MARK: PSN review "own the ticked rows as" segmented control (the owner's dead-control fix)

    @Test(.timeLimit(.minutes(2)))
    func psnReviewOwnAsSegmentSwitchesFormat() async throws {
        let db = try AppDatabase.inMemory()
        let staging = ImportStagingStore(db)
        // One "Played — no purchase found" row (played > 10 min), pre-ticked, so the own-as
        // control is present and enabled.
        let rows = [ImportStagingRow(source: ImportSourceID.psn, externalID: "p", name: "Bloodborne",
                                     platform: "ps4", signals: [.played], playDurationS: 3600)]
        try await staging.upsert(rows)
        let result = ImportSyncResult(summary: ImportSyncSummary(source: ImportSourceID.psn),
                                      matches: [], rows: rows)
        let model = ImportReviewModel(source: ImportSourceID.psn, sourceLabel: "PlayStation",
                                      staging: staging, result: result, productFormat: .digital,
                                      platformChoices: PSNImportPresenter.platformChoices)
        await model.load()
        #expect(model.ownAsSelection == nil)   // default: not owned

        // The own-as control is the only NSSegmentedControl in the PSN review sheet; click its
        // "Digital" segment (index 2 of Not owned | Physical | Digital) and assert the model
        // switched — the real click→model path the owner's bug broke (an off-screen render can't
        // show the selection highlight, but the click drives the model).
        let window = ClickProbeWindow(ImportReviewSheet(model: model)
            .frame(minWidth: 700, minHeight: 460).toolbar { Button("x") {} },
            size: NSSize(width: 720, height: 480))
        defer { window.close() }
        await window.settleShort()
        #expect(window.hasSegmentedControl(), "the own-as segmented control should be present")
        #expect(await window.clickSegment(2, of: 3), "the own-as segmented control was not located")
        let switched = await window.poll { model.ownAsSelection == .digital }
        #expect(switched, "clicking the Digital segment did not switch the own-as format")
    }
}

/// A network-free ``ChooseCoverProviding`` for the Choose Cover click test.
private final class FakeChooseCoverBackend: ChooseCoverProviding, @unchecked Sendable {
    let candidates: [CoverCandidate]
    init(_ candidates: [CoverCandidate]) { self.candidates = candidates }
    func coverCandidates(forGameID id: Int64) async -> [CoverCandidate] { candidates }
    func candidateThumbnail(for candidate: CoverCandidate, maxPixel: Int) async -> sending CGImage? { nil }
    func chooseCandidate(_ candidate: CoverCandidate, forGameID id: Int64) async throws {}
    func importCoverFile(_ url: URL, forGameID id: Int64) async throws {}
}
