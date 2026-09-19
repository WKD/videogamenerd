import AppKit
import SwiftUI
import Testing
@testable import VGN

/// Real mouse clicks (via ``ClickProbeWindow``) against the reconcile UI's primary
/// controls: the merge sheet's buttons and the inspector's "Link…" affordance. Model
/// tests can't see hit-testing bugs (PLAN §5.1).
@MainActor
@Suite(.serialized)
struct ReconcileClickTests {

    private func copy(_ pid: Int64, _ source: ProductSource) -> ReconcileCopy {
        ReconcileCopy(productID: pid, platformID: "ps3", format: .physical, source: source,
                      externalID: nil, edition: nil, region: nil, acquiredAt: nil,
                      psnEntitlement: nil, isCompilation: false)
    }

    @Test(.timeLimit(.minutes(5)))
    func mergeSheetButtonsReceiveClicks() async throws {
        let source = copy(1, .delicious)
        let target = copy(2, .photo)
        let decisions = MergePlanner.plan(source: [source], target: [target])
        let inputs = MergeInputs(
            sourceGameID: 1, targetGameID: 2, sourceTitle: "Weird Edition", targetTitle: "Real Game",
            sourceCopies: [source], targetCopies: [target], decisions: decisions,
            detailLines: ["Played", "Tier & rank kept"], bothRanked: false)
        let model = IGDBMergeModel(inputs: inputs)
        var events = 0
        model.onConfirm = { _ in events += 1 }
        model.onCancel = { events += 1 }

        let size = NSSize(width: 480, height: 480)
        let window = ClickProbeWindow(IGDBMergeSheet(model: model), size: size)
        defer { window.close() }
        try await window.settle()

        let hits = try await window.sweep(band: size.height, stepX: 16, stepY: 12) {
            events
        } until: { events > 0 }
        #expect(hits >= 1, "the merge sheet's Merge/Cancel buttons never received a click")
        #expect(events > 0)
    }

    @Test(.timeLimit(.minutes(5)))
    func inspectorLinkButtonReceivesClicks() async throws {
        let game = GameSummary(id: 1, title: "Unlinked Game", year: 2005, played: true, owned: true,
                               platformIDs: ["snes"])
        let vm = LibraryViewModel(dataSource: PreviewLibraryDataSource(games: [game]))
        var linkRequests = 0
        vm.onLinkToIGDB = { _ in linkRequests += 1 }
        vm.start()
        vm.selectOnly(1)
        for _ in 0..<500 where vm.selectedDetail == nil { await Task.yield() }
        #expect(vm.selectedDetail?.igdbID == nil)      // preview detail is unlinked

        let size = NSSize(width: 320, height: 680)
        let window = ClickProbeWindow(InspectorView(vm: vm), size: size)
        defer { window.close() }
        try await window.settle()

        let hits = try await window.sweep(band: size.height, stepX: 14, stepY: 12) {
            linkRequests
        } until: { linkRequests > 0 }
        #expect(hits >= 1, "the inspector's Link affordance never received a click")
        #expect(linkRequests > 0)
    }
}
