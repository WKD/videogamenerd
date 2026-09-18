#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Duel, Triage, Tier Board and The Top (PLAN §7), plus the border card,
/// disputes sheet and tier legend. Models are driven with the scripted backend
/// and `start()`ed before capture so the populated state is what renders.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: snapshotSuitesEnabled()))
struct RankingSnapshotTests {
    private let group = "04 Ranking"

    // MARK: Duel

    @Test func duelPlacement() async {
        let model = DuelModel(backend: ScriptedRankingBackend.previewPlacement())
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-duel-placement", size: SnapSize(width: 900, height: 660)) {
            DuelView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func duelRefine() async {
        let model = DuelModel(backend: ScriptedRankingBackend.previewRefine())
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-duel-refine", size: SnapSize(width: 900, height: 660)) {
            DuelView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func duelBorder() async {
        let model = DuelModel(backend: ScriptedRankingBackend.previewBorder())
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-duel-border", size: SnapSize(width: 900, height: 660)) {
            DuelView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func duelEmpty() async {
        let model = DuelModel(backend: ScriptedRankingBackend.previewEmpty())
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-duel-empty", size: SnapSize(width: 800, height: 560)) {
            DuelView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func disputesSheet() async {
        await SnapshotHarness.capture(group: group, "ranking-disputes",
                                      size: SnapSize(width: 520, height: 420), settle: 4) {
            DisputesSheet(
                disputes: [Consistency.Dispute(games: [1, 2, 3], cycle: [1, 2, 3])],
                titles: [1: "Bloodborne", 2: "Sekiro", 3: "Elden Ring"],
                onSettle: { _ in }, onClose: {})
        }
    }

    // MARK: Triage

    @Test func triageActive() async {
        let model = TriageModel(backend: ScriptedRankingBackend.previewTriage())
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-triage", size: SnapSize(width: 660, height: 660)) {
            TriageView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func triageDone() async {
        let backend = ScriptedRankingBackend.previewTriage()
        backend.unranked = []
        let model = TriageModel(backend: backend)
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-triage-done", size: SnapSize(width: 660, height: 660)) {
            TriageView(model: model, loader: NoopCoverLoader())
        }
    }

    // MARK: Tier Board

    @Test func tierBoardSmall() async {
        let model = TierBoardModel(backend: ScriptedRankingBackend.previewBoard(placedPerTier: 3, unplacedPerTier: 1))
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-tierboard-small", size: .large,
                                      appearances: SnapAppearance.allCases) {
            TierBoardView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func tierBoardEmpty() async {
        let model = TierBoardModel(backend: ScriptedRankingBackend.previewBoard(placedPerTier: 0, unplacedPerTier: 0))
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-tierboard-empty", size: SnapSize(width: 900, height: 620)) {
            TierBoardView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func tierBoard300() async {
        let model = TierBoardModel(backend: ScriptedRankingBackend.previewBoard(placedPerTier: 50, unplacedPerTier: 0))
        await model.start()
        await SnapshotHarness.settle(rounds: 5)
        await SnapshotHarness.capture(group: group, "ranking-tierboard-300", size: .large) {
            TierBoardView(model: model, loader: NoopCoverLoader())
        }
    }

    // MARK: The Top

    @Test func theTopUnfiltered() async {
        let model = TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 24))
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-top-unfiltered", size: SnapSize(width: 760, height: 760)) {
            TheTopView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func theTopFiltered() async {
        let model = TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 24, filtered: true),
                                filter: LibraryFilter(scope: .platform("ps2")))
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-top-filtered", size: SnapSize(width: 760, height: 760)) {
            TheTopView(model: model, loader: NoopCoverLoader())
        }
    }

    @Test func theTopShort() async {
        let model = TheTopModel(backend: ScriptedRankingBackend.previewTop(n: 5))
        await model.start()
        await SnapshotHarness.settle(rounds: 4)
        await SnapshotHarness.capture(group: group, "ranking-top-short", size: SnapSize(width: 720, height: 520)) {
            TheTopView(model: model, loader: NoopCoverLoader())
        }
    }

    // MARK: Legend + unavailable

    @Test func tierLegend() async {
        await SnapshotHarness.capture(group: group, "ranking-tier-legend",
                                      size: SnapSize(width: 520, height: 120), settle: 3) {
            RankingTierLegend(tiers: TierInfo.defaults, highlighted: 2) { _ in }.padding()
        }
    }

    @Test func rankingUnavailable() async {
        await SnapshotHarness.capture(group: group, "ranking-unavailable",
                                      size: SnapSize(width: 700, height: 480), settle: 3) {
            RankingDestinationView(selection: .duel)
        }
    }
}
#endif
