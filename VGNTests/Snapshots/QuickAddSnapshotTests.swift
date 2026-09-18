#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// The Quick Add palette content (PLAN §6.1). Driven through the real search
/// path (scripted catalogue + library fakes, tiny debounce) so the rows, flags
/// and confirmation are the genuine rendered state. The floating `NSPanel`
/// chrome / key handling is out of scope for off-screen rendering (see the doc).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QuickAddSnapshotTests {
    private let group = "03 Quick Add"
    private let size = SnapSize(width: 600, height: 560)

    private func liveResults() -> [IGDBSearchResult] {
        [
            makeSearchResult(id: 1, name: "Elden Ring", year: 2022, platforms: ["ps5", "ps4", "pc"], coverImageID: "co1"),
            makeSearchResult(id: 2, name: "Elden Ring: Shadow of the Erdtree", year: 2024, platforms: ["ps5", "pc"]),
            makeSearchResult(id: 3, name: "Elderand", year: 2023, platforms: ["switch", "pc"]),
        ]
    }

    private func bundleResults() -> [IGDBSearchResult] {
        [
            makeSearchResult(id: 10, name: "Metal Gear Solid: The Legacy Collection", year: 2013,
                             platforms: ["ps3"], bundle: true),
            makeSearchResult(id: 11, name: "Metal Gear Solid 3: Snake Eater", year: 2004, platforms: ["ps2", "ps3"]),
        ]
    }

    /// Prepare + drive a model to a searched state.
    private func drive(query: String, results: [IGDBSearchResult], local: [QuickAddLibraryMatch],
                       credentials: Bool) async -> QuickAddModel {
        let catalog = FakeCatalog()
        await catalog.configure(results: results, credentials: credentials)
        let library = FakeLibrary()
        await library.setLocal(local)
        let model = makeQuickAddModel(catalog: catalog, library: library, debounce: .milliseconds(1))
        model.prepare(sidebarPlatform: "ps5",
                      ownedPlatforms: ["ps5", "ps4", "ps2", "ps3"],
                      tiers: TierInfo.defaultTiers)
        model.query = query
        await SnapshotHarness.settle(rounds: 8)
        return model
    }

    @Test func idle() async {
        let model = await drive(query: "", results: [], local: [], credentials: true)
        await SnapshotHarness.capture(group: group, "quickadd-idle", size: size) {
            QuickAddView(model: model, coverLoader: NoopCoverLoader()).padding(20)
        }
    }

    @Test func results() async {
        let local = [makeLibraryMatch(id: 90, title: "Elden Ring", platforms: ["ps4"], owned: true, played: true)]
        let model = await drive(query: "elden", results: liveResults(), local: local, credentials: true)
        await SnapshotHarness.capture(group: group, "quickadd-results", size: size) {
            QuickAddView(model: model, coverLoader: NoopCoverLoader()).padding(20)
        }
    }

    @Test func bundleRow() async {
        let model = await drive(query: "metal gear legacy", results: bundleResults(), local: [], credentials: true)
        await SnapshotHarness.capture(group: group, "quickadd-bundle", size: size) {
            QuickAddView(model: model, coverLoader: NoopCoverLoader()).padding(20)
        }
    }

    @Test func offlineHint() async {
        let local = [makeLibraryMatch(id: 91, title: "Disco Elysium", platforms: ["pc"], owned: true)]
        let model = await drive(query: "disco", results: [], local: local, credentials: false)
        await SnapshotHarness.capture(group: group, "quickadd-offline", size: size) {
            QuickAddView(model: model, coverLoader: NoopCoverLoader()).padding(20)
        }
    }

    @Test func confirmation() async {
        let model = await drive(query: "elden", results: liveResults(), local: [], credentials: true)
        model.setTier("A")
        model.commit(openInspector: false)
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "quickadd-confirmation", size: size) {
            QuickAddView(model: model, coverLoader: NoopCoverLoader()).padding(20)
        }
    }
}
#endif
