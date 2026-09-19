#if DEBUG
import SwiftUI
import Testing
@testable import VGN

/// Off-screen snapshot renders of the Batocera screens (PLAN §15). New cases only — never a
/// re-record of an existing reference. Opt-in like every snapshot suite (VGN_SNAPSHOTS=1).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: snapshotSuitesEnabled()))
struct BatoceraSnapshotTests {
    private let group = "15 Batocera"

    private func seededModel() async throws -> (BatoceraEnvironment, RomCatalogueModel) {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        var entries: [RomCatalogEntry] = []
        let names = ["The Legend of Zelda", "Super Metroid", "Chrono Trigger", "Secret of Mana",
                     "Super Mario World", "Contra III", "Final Fantasy VI", "Castlevania IV"]
        for (i, name) in names.enumerated() {
            let g = BatoceraGame(system: "snes", relativePath: "./g\(i).zip", name: name,
                                 genre: ["Adventure", "Platform", "Role Playing Game"][i % 3],
                                 releaseYear: 1990 + i, rating: 0.7 + Double(i) * 0.03,
                                 gameTimeSeconds: i == 0 ? 7200 : 0, isFavorite: i == 1)
            entries.append(RomCatalogEntry.make(from: g, platformID: "snes", libretroKey: "g\(i)"))
        }
        _ = try await store.syncSystem(system: "snes", entries: entries)
        let env = BatoceraEnvironment(
            catalog: store, thumbnails: BatoceraThumbnailLoader(romsRoot: nil),
            discover: InertDiscoverBackend(), isLive: false, romsRoot: nil,
            addToLibrary: { _ in }, inspectGame: nil, showCatalogue: nil)
        let model = RomCatalogueModel(catalog: store)
        model.start()
        return (env, model)
    }

    @Test func romCatalogueBrowser() async throws {
        let (env, model) = try await seededModel()
        await SnapshotHarness.settle(rounds: 6)
        await SnapshotHarness.capture(group: group, "batocera-catalogue") {
            RomCatalogueContent(env: env, model: model).frame(width: 820, height: 560)
        }
    }

    @Test func settingsPane() async {
        BatoceraPreferences.shareFolderPath = "/Volumes/share"
        let model = BatoceraSettingsModel(
            backend: FakeBatoceraBackend(isLive: false,
                                         status: BatoceraCatalogStatus(totalEntries: 11_300,
                                                                       systemsCount: 40, candidatesWaiting: 290)))
        BatoceraPreferences.shareFolderPath = nil
        await SnapshotHarness.settle(rounds: 3)
        await SnapshotHarness.capture(group: group, "batocera-settings", size: SnapSize(width: 560, height: 620)) {
            BatoceraSettingsTab(model: model)
        }
    }

    @Test func discoverCard() async {
        let entry = RomCatalogEntry(
            id: 1, source: "batocera", system: "snes", platformID: "snes",
            relativePath: "./mana.zip", name: "Secret of Mana", genre: "Role Playing Game",
            releaseYear: 1993, rating: 0.88)
        let item = DiscoverItem(entry: entry,
                                sentences: ["Part of Mana, like **Secret of Evermore** (A)",
                                            "You rate role-playing games highly"],
                                strength: .strong)
        await SnapshotHarness.capture(group: group, "batocera-discover-card") {
            DiscoverCardView(item: item, loader: nil, onAdd: {}, onNotInterested: {}, onShowInCatalogue: {})
                .padding(20)
        }
    }
}
#endif
