import Foundation
import Testing
@testable import VGN

/// The change-detecting sync end to end (PLAN §15), over a synthetic on-disk share tree —
/// never `/Volumes/…`. Covers skip/unknown handling, folding, upsert, change detection and
/// the quiet unmounted result.
struct BatoceraSyncTests {

    private func spec(_ path: String, name: String, gametime: Int = 0, favorite: Bool = false)
        -> BatoceraTestSupport.GameSpec {
        .init(path: path, name: name, gametime: gametime == 0 ? nil : String(gametime),
              favorite: favorite ? "true" : nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func syncReadsMappedSystemsSkipsArcadeReportsUnknownAndFolds() async throws {
        let root = try BatoceraTestSupport.makeShareTree([
            "snes": [spec("Mario.zip", name: "Super Mario World", gametime: 900),
                     spec("Metroid.zip", name: "Super Metroid", favorite: true)],
            "psx": [spec("Final Fantasy VII (USA) (Disc 1).chd", name: "Final Fantasy VII"),
                    spec("Final Fantasy VII (USA) (Disc 2).chd", name: "Final Fantasy VII"),
                    spec("Final Fantasy VII (USA) (Disc 3).chd", name: "Final Fantasy VII")],
            "mame": [spec("sf2.zip", name: "Street Fighter II")],   // arcade → skipped
            "sg1000": [spec("x.zip", name: "Unknown System Game")], // no slug → unknown
        ])
        defer { BatoceraTestSupport.removeTree(root) }

        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let sync = BatoceraSync(store: store)
        let summary = await sync.sync(root: root)

        #expect(summary.shareUnavailable == false)
        #expect(summary.systemsRead == 2)                       // snes + psx
        #expect(summary.systemsSkipped == 1)
        #expect(summary.skippedSystems == ["mame"])
        #expect(summary.unknownSystems == ["sg1000"])
        #expect(summary.foldedDuplicates == 2)                  // 3 FF7 discs → 1
        #expect(summary.entriesAdded == 3)                      // Mario, Metroid, FF7
        #expect(summary.candidateCount == 2)                    // Mario (played) + Metroid (fav)

        #expect(try await store.totalCount() == 3)
        #expect(try await store.countsPerSystem() == ["snes": 2, "psx": 1])
    }

    @Test(.timeLimit(.minutes(1)))
    func secondSyncSkipsUnchangedSystems() async throws {
        let root = try BatoceraTestSupport.makeShareTree([
            "snes": [spec("Mario.zip", name: "Super Mario World")],
        ])
        defer { BatoceraTestSupport.removeTree(root) }

        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        let sync = BatoceraSync(store: store)

        let first = await sync.sync(root: root)
        #expect(first.systemsRead == 1)

        let second = await sync.sync(root: root)          // no file change
        #expect(second.systemsRead == 0)
        #expect(second.systemsUnchanged == 1)

        // A forced sync re-reads.
        let forced = await sync.sync(root: root, force: true)
        #expect(forced.systemsRead == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func unmountedShareIsQuiet() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-share-\(UUID().uuidString)", isDirectory: true)
        let db = try await BatoceraTestSupport.makeSeededDB()
        let sync = BatoceraSync(store: RomCatalogStore(db))
        let summary = await sync.sync(root: missing)
        #expect(summary.shareUnavailable == true)
        #expect(summary.systemsRead == 0)
        #expect(summary.failures.isEmpty)
    }
}
