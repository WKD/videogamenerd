import Foundation
import Testing
@testable import VGN

/// Bundle expansion in the import matching phase (PLAN §5.1): the coordinator fetches a
/// bundle match's members through the injected expander (a fake here — no network) and
/// carries them into ``ImportSyncResult/bundleExpansions``. Empty coverage falls back to a
/// single. No network.
@Suite(.serialized) struct ImportBundleExpansionTests {

    /// A fake importer returning one preset staging row.
    private struct FakeImporter: LibraryImporter {
        let source = ImportSourceID.delicious
        var dataSets: [ImportDataSet] { [] }
        let rows: [ImportStagingRow]
        func authenticate() async throws {}
        func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
            ImportFetchResult(rows: rows, fromFile: rows.count)
        }
    }

    /// A matcher that returns a preset outcome for every request.
    private struct FixedMatcher: ImportMatcher {
        let outcome: ScanMatchOutcome
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome { outcome }
    }

    /// A fake bundle expander returning preset members per bundle id.
    private struct FakeExpander: ImportBundleExpanding {
        let membersByID: [Int64: [IGDBSearchResult]]
        func members(ofBundleIGDBID igdbID: Int64) async throws -> BundleMemberResult {
            BundleMemberResult(members: membersByID[igdbID] ?? [])
        }
    }

    private func searchResult(_ id: Int64, _ name: String, bundle: Bool = false) -> IGDBSearchResult {
        IGDBSearchResult(id: id, name: name, releaseYear: nil, coverImageID: nil,
                         platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                         genres: [], alternativeNames: [], gameType: bundle ? .bundle : .mainGame)
    }

    private func bundleMatch(_ id: Int64, _ name: String) -> ScanMatchOutcome {
        ScanMatchOutcome(
            best: ScanMatch(igdbID: id, name: name, releaseYear: nil, coverImageID: nil,
                            platformSlugs: [], score: 0.97, matchedName: name, gameType: .bundle),
            alternatives: [], bucket: .confident)
    }

    @Test(.timeLimit(.minutes(1)))
    func coordinatorExpandsBundleMatch() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)

        let rows = [ImportStagingRow(source: ImportSourceID.delicious, externalID: "b1",
                                     name: "The Tomb Raider Trilogy", platform: "ps3")]
        let importer = FakeImporter(rows: rows)
        let matcher = FixedMatcher(outcome: bundleMatch(500, "The Tomb Raider Trilogy"))
        let expander = FakeExpander(membersByID: [500: [
            searchResult(1, "Tomb Raider: Legend"),
            searchResult(2, "Tomb Raider: Anniversary"),
            searchResult(3, "Tomb Raider: Underworld"),
        ]])

        let result = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        let expansion = try #require(result.bundleExpansions["b1"])
        #expect(expansion.hasMembers)
        #expect(expansion.members.count == 3)
        #expect(expansion.members.map(\.title) == ["Tomb Raider: Legend", "Tomb Raider: Anniversary",
                                                   "Tomb Raider: Underworld"])
        #expect(expansion.members.map(\.position) == [0, 1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyCoverageFallsBackToNoExpansion() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)

        let rows = [ImportStagingRow(source: ImportSourceID.delicious, externalID: "b1",
                                     name: "Mystery Collection", platform: "ps3")]
        let importer = FakeImporter(rows: rows)
        let matcher = FixedMatcher(outcome: bundleMatch(999, "Mystery Collection"))
        let expander = FakeExpander(membersByID: [:])   // no members known

        let result = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        // An entry may be recorded but with no members → the review commits it as a single.
        #expect(result.bundleExpansions["b1"]?.hasMembers != true)
    }

    @Test(.timeLimit(.minutes(1)))
    func noExpanderLeavesExpansionsEmpty() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let rows = [ImportStagingRow(source: ImportSourceID.delicious, externalID: "b1",
                                     name: "The Tomb Raider Trilogy", platform: "ps3")]
        let result = try await coordinator.run(
            FakeImporter(rows: rows), matcher: FixedMatcher(outcome: bundleMatch(500, "x")))
        #expect(result.bundleExpansions.isEmpty)
    }

    @Test func mappingPreservesOrderAndOwnedNotPlayed() {
        let members = ImportBundleMapping.members(from: [
            searchResult(10, "A"), searchResult(20, "B")])
        #expect(members.count == 2)
        #expect(members.allSatisfy { !$0.played })
        #expect(members.map(\.igdbID) == [10, 20])
        #expect(members.map(\.position) == [0, 1])
    }
}
