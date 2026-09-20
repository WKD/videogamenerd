import Foundation
import Testing
@testable import VGN

/// GRDB-backed Quick Add wiring (the live `LibraryAdding` adapter) plus the
/// `AppEnvironment` composition guarantees. `@MainActor` + serialized because the
/// live tests touch a GRDB queue (see `LiveWiringTests`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QuickAddEnvironmentTests {

    // MARK: - Live library adder

    @Test func liveAdderFindsLocalMatchesAndAdds() async throws {
        let store = try await UIWiring.makeStore()
        let adder = LiveLibraryAdder(store: store)

        _ = try await adder.add(GameDraft(title: "Halo", platformIDs: ["ps4"], owned: true))
        let matches = await adder.localMatches("Halo")
        #expect(matches.contains { $0.title == "Halo" && $0.owned })

        // Short queries never dump the whole library.
        #expect(await adder.localMatches("H").isEmpty)
    }

    @Test func liveAdderCreatesCompilation() async throws {
        let store = try await UIWiring.makeStore()
        let adder = LiveLibraryAdder(store: store)

        let (productID, members) = try await adder.addCompilation(
            product: ProductDraft(title: "Legacy Collection", platformID: "ps2"),
            members: [
                CompilationMemberDraft(title: "MGS2", played: true, position: 0),
                CompilationMemberDraft(title: "MGS3", played: true, position: 1),
            ]
        )
        #expect(productID > 0)
        #expect(members.count == 2)

        let memberID = members[0].gameID
        let detail = try await store.gameDetail(id: memberID)
        #expect(detail?.owned == true)                       // owned via the compilation product
        #expect(detail?.copies.first?.kind == .compilation)
    }

    // MARK: - Environment hookup

    @Test func sampleModeUsesTempDirectoriesNotTheRealLibrary() {
        let live = AppEnvironment.serviceDirectories(for: .live)
        #expect(live.covers == nil && live.thumbs == nil && live.libretro == nil)

        let sample = AppEnvironment.serviceDirectories(for: .sampleData)
        let tempRoot = FileManager.default.temporaryDirectory.path
        #expect(sample.covers?.path.hasPrefix(tempRoot) == true)
        #expect(sample.thumbs?.path.hasPrefix(tempRoot) == true)
        #expect(sample.libretro?.path.hasPrefix(tempRoot) == true)
        // Never under the real Application Support library.
        #expect(sample.covers?.path.contains("Application Support/VGN") == false)
    }

    @Test func offlineSearcherNeverTouchesTheNetwork() async throws {
        let searcher = OfflineCatalogSearcher()
        #expect(await searcher.hasCredentials() == false)
        await #expect(throws: IGDBError.self) {
            _ = try await searcher.search("bloodborne", platformIGDBIDs: nil, limit: 12)
        }
        let members = try await searcher.bundleMembers(bundleIGDBID: 1)
        #expect(members.members.isEmpty)
    }

    @Test func xctestHostBuildsNothing() {
        // Under the unit-test host, launch() must not open the real DB or build any
        // services (the whole window/services graph is skipped).
        #expect(VGNApp.isRunningUnitTests)
        let env = AppEnvironment.launch()
        #expect(env.library == nil)
        #expect(env.services == nil)
        #expect(env.quickAdd == nil)
        #expect(env.quickAddController == nil)
        #expect(env.enrichment == nil)
        #expect(env.failure == nil)
    }
}
