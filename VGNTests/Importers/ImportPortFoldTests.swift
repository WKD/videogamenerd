import Foundation
import Testing
@testable import VGN

/// Import matching folds a **port** best-match onto its parent game (PLAN §5.1 D4 — "a
/// port is the same game"): a Switch/PS4 port of an older game imports as a copy on the one
/// game. The coordinator resolves the parents once per sync (through ``ImportBundleExpanding``)
/// and re-persists the resolved outcome so a resume never re-resolves. No network.
@Suite(.serialized) struct ImportPortFoldTests {

    private struct FakeImporter: LibraryImporter {
        let source: String
        let rows: [ImportStagingRow]
        var dataSets: [ImportDataSet] { [] }
        func authenticate() async throws {}
        func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
            ImportFetchResult(rows: rows, fromFile: rows.count)
        }
    }

    private struct FixedMatcher: ImportMatcher {
        let outcome: ScanMatchOutcome
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome { outcome }
    }

    /// An expander that resolves ports from a fixed parent table (and counts its calls).
    private final class PortExpander: ImportBundleExpanding, @unchecked Sendable {
        let parents: [Int64: IGDBGameMetadata]
        private let lock = NSLock(); private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        init(_ parents: [Int64: IGDBGameMetadata]) { self.parents = parents }
        func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult { BundleMemberResult() }
        func resolvingPortParents(_ matches: [ScanMatch]) async -> [ScanMatch] {
            lock.withLock { _calls += 1 }
            return matches.map { m in
                guard m.gameType == .port, let pid = m.foldParentID, let parent = parents[pid],
                      GameTypePolicy.isStandaloneGame(parent.gameType) else { return m }
                return ScanMatch(resolvingPort: m, to: parent)
            }
        }
    }

    private func portOutcome(portID: Int64, parentID: Int64) -> ScanMatchOutcome {
        let best = ScanMatch(igdbID: portID, name: "Super Mario Galaxy", releaseYear: 2020,
                             coverImageID: nil, platformSlugs: ["switch"], score: 0.95,
                             matchedName: "Super Mario Galaxy", gameType: .port, foldParentID: parentID)
        return ScanMatchOutcome(best: best, alternatives: [], bucket: .confident)
    }

    private func parent(_ id: Int64, _ name: String, year: Int?) -> IGDBGameMetadata {
        IGDBGameMetadata(id: id, name: name, slug: nil, summary: nil, releaseDate: nil, releaseYear: year,
                         coverImageID: nil, platformIGDBIDs: [], platformSlugs: [], genres: [],
                         alternativeNames: [], gameType: .mainGame, bundleMemberIDs: [],
                         parentGameID: nil, versionParentID: nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func portBestMatchBecomesTheParent() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: [
            ImportStagingRow(source: "gog", externalID: "1", name: "Super Mario Galaxy", platform: "switch")])
        let matcher = FixedMatcher(outcome: portOutcome(portID: 20, parentID: 10))
        let expander = PortExpander([10: parent(10, "Super Mario Galaxy", year: 2007)])

        let r = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        let best = try #require(r.matches.first?.outcome.best)
        #expect(best.igdbID == 10)                    // the original, not the port
        #expect(best.resolvedFromPortID == 20)
        #expect(best.gameType == .mainGame)

        // Persisted as the parent → a second sync reuses it without resolving again.
        let attempts = try await staging.persistedAttempts(source: "gog")
        #expect(attempts["1"]?.match?.outcome.best?.igdbID == 10)
        #expect(attempts["1"]?.match?.outcome.best?.resolvedFromPortID == 20)
    }

    @Test(.timeLimit(.minutes(1)))
    func unresolvablePortKeepsThePortEntry() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: [
            ImportStagingRow(source: "gog", externalID: "1", name: "Weird Port", platform: "switch")])
        let matcher = FixedMatcher(outcome: portOutcome(portID: 20, parentID: 99))
        let expander = PortExpander([:])   // parent 99 not in the table

        let r = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        let best = try #require(r.matches.first?.outcome.best)
        #expect(best.igdbID == 20)                    // the port stays
        #expect(best.resolvedFromPortID == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func noExpanderLeavesThePortUnchanged() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: [
            ImportStagingRow(source: "gog", externalID: "1", name: "Super Mario Galaxy", platform: "switch")])
        let matcher = FixedMatcher(outcome: portOutcome(portID: 20, parentID: 10))

        let r = try await coordinator.run(importer, matcher: matcher)   // no bundleExpander
        #expect(r.matches.first?.outcome.best?.igdbID == 20)
    }
}
