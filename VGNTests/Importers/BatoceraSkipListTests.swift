import Foundation
import Testing
@testable import VGN

/// The editable skip list (PLAN §15 phase 2): the default list is the built-in arcade +
/// non-collection systems; an explicit skip set is authoritative (removing an entry un-skips
/// it) while the arcade romset families (`mame*`/`cps*`) are always skipped; and a sync honours
/// the override so skipped systems never enter the catalogue.
struct BatoceraSkipListTests {

    @Test func defaultSkipListIsTheBuiltInSets() {
        let list = Set(BatoceraSystems.defaultSkipList)
        #expect(list.contains("mame"))
        #expect(list.contains("neogeo"))
        #expect(list.contains("steam"))
        #expect(!list.contains("snes"))
    }

    @Test func explicitSkipSetIsAuthoritative() {
        // With the default set, daphne is skipped; with an empty set it is no longer skipped
        // (it maps to no slug ⇒ unknown, not a family).
        #expect(BatoceraSystems.classify("daphne") == .skipped)
        #expect(BatoceraSystems.classify("daphne", skip: []) == .unknown)
        // A mapped system stays mapped whatever the skip set (unless listed).
        #expect(BatoceraSystems.classify("snes", skip: ["gamegear"]) == .mapped(slug: "snes"))
        #expect(BatoceraSystems.classify("gamegear", skip: ["gamegear"]) == .skipped)
    }

    @Test func removingANonFamilyEntryUnSkipsIt() {
        var skip = Set(BatoceraSystems.defaultSkipList)
        skip.remove("steam")
        // "steam" has no slug, so removing it from the list makes it unknown (not skipped).
        #expect(BatoceraSystems.classify("steam", skip: skip) == .unknown)
    }

    @Test func arcadeFamiliesAlwaysSkippedEvenWhenNotListed() {
        #expect(BatoceraSystems.classify("mame2003", skip: []) == .skipped)
        #expect(BatoceraSystems.classify("cps2", skip: []) == .skipped)
        #expect(BatoceraSystems.isArcadeFamily("mame2010"))
        #expect(BatoceraSystems.isArcadeFamily("cps3"))
        #expect(!BatoceraSystems.isArcadeFamily("snes"))
    }

    @Test(.timeLimit(.minutes(1)))
    func syncHonoursTheSkipOverride() async throws {
        let db = try await BatoceraTestSupport.makeSeededDB()
        let store = RomCatalogStore(db)
        // Two systems on the share: snes (kept) and "gamegear" that the owner chose to skip.
        let root = try BatoceraTestSupport.makeShareTree([
            "snes": [.init(path: "./A (USA).zip", name: "A")],
            "gamegear": [.init(path: "./B (USA).zip", name: "B")],
        ])
        defer { BatoceraTestSupport.removeTree(root) }

        let sync = BatoceraSync(store: store)
        let summary = await sync.sync(root: root, force: true, skip: ["gamegear"])
        #expect(summary.skippedSystems.contains("gamegear"))
        // Only snes made it into the catalogue.
        let systems = try await store.countsPerSystem()
        #expect(systems["snes"] == 1)
        #expect(systems["gamegear"] == nil)
    }
}
