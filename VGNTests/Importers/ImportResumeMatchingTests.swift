import Foundation
import Testing
@testable import VGN

/// Resume matching after cancel / on a second sync (PLAN §5.1, wave 16): the coordinator
/// persists each *New* row's match outcome (`match_attempted_at` + `match_json`), so a rerun
/// skips already-attempted titles (never re-querying IGDB), restores their alternatives and
/// bundle members, re-queries a no-match only after 30 days (or on an explicit "Re-match"),
/// and reports "N already matched". No network — a counting fake matcher / expander.
@Suite(.serialized) struct ImportResumeMatchingTests {

    private struct FakeImporter: LibraryImporter {
        let source: String
        let rows: [ImportStagingRow]
        var dataSets: [ImportDataSet] { [] }
        func authenticate() async throws {}
        func fetch(progress: @Sendable @escaping (ImportProgress) -> Void) async throws -> ImportFetchResult {
            ImportFetchResult(rows: rows, fromFile: rows.count)
        }
    }

    private final class CountingMatcher: ImportMatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        let outcome: ScanMatchOutcome
        init(_ outcome: ScanMatchOutcome) { self.outcome = outcome }
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            lock.withLock { _count += 1 }
            return outcome
        }
    }

    private final class CountingExpander: ImportBundleExpanding, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        let members: [IGDBSearchResult]
        init(members: [IGDBSearchResult]) { self.members = members }
        func members(ofBundleIGDBID igdbID: Int64) async throws -> [IGDBSearchResult] {
            lock.withLock { _count += 1 }
            return members
        }
    }

    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [ImportProgress] = []
        var matchingDetails: [String] { lock.withLock { _values.filter { $0.phase == .matching }.map(\.detail) } }
        func record(_ p: ImportProgress) { lock.withLock { _values.append(p) } }
    }

    private func confident(_ id: Int64, _ name: String, alts: Int = 2) -> ScanMatchOutcome {
        let best = ScanMatch(igdbID: id, name: name, releaseYear: 2020, coverImageID: nil,
                             platformSlugs: ["pc"], score: 0.95, matchedName: name)
        let alternatives = (0..<alts).map { i in
            ScanMatch(igdbID: id * 10 + Int64(i), name: "\(name) \(i)", releaseYear: 2021,
                      coverImageID: nil, platformSlugs: ["pc"], score: 0.80, matchedName: "\(name) \(i)")
        }
        return ScanMatchOutcome(best: best, alternatives: alternatives, bucket: .confident)
    }
    private var noMatch: ScanMatchOutcome { ScanMatchOutcome(best: nil, alternatives: [], bucket: .none) }

    private func rows(_ source: String, _ n: Int) -> [ImportStagingRow] {
        (1...n).map { ImportStagingRow(source: source, externalID: "\($0)", name: "Game \($0)", platform: "pc") }
    }

    // MARK: - Reuse on a second run

    @Test(.timeLimit(.minutes(1)))
    func secondRunSkipsAttemptedTitlesAndRestoresAlternatives() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: rows("gog", 3))
        let matcher = CountingMatcher(confident(101, "Game", alts: 2))

        let r1 = try await coordinator.run(importer, matcher: matcher)
        #expect(matcher.count == 3)
        #expect(r1.matches.count == 3)

        let r2 = try await coordinator.run(importer, matcher: matcher)
        #expect(matcher.count == 3)              // nothing re-queried
        #expect(r2.matches.count == 3)
        // Alternatives round-trip through the persisted JSON.
        #expect(r2.matches.allSatisfy { $0.outcome.alternatives.count == 2 })
        #expect(r2.matches.first?.outcome.best?.igdbID == 101)
    }

    // MARK: - 30-day re-query rule for a no-match

    @Test(.timeLimit(.minutes(1)))
    func noMatchIsReusedWithinTTLAndReQueriedAfter() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: rows("gog", 1))
        let matcher = CountingMatcher(noMatch)

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await coordinator.run(importer, matcher: matcher, now: t0)
        #expect(matcher.count == 1)

        // One day later: still trusted, not re-queried.
        _ = try await coordinator.run(importer, matcher: matcher, now: t0.addingTimeInterval(86_400))
        #expect(matcher.count == 1)

        // 31 days later: the no-match is stale → re-queried.
        _ = try await coordinator.run(importer, matcher: matcher, now: t0.addingTimeInterval(31 * 86_400))
        #expect(matcher.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func reMatchClearsTheAttempt() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: rows("gog", 1))
        let matcher = CountingMatcher(confident(7, "Game"))

        _ = try await coordinator.run(importer, matcher: matcher)
        #expect(matcher.count == 1)
        _ = try await coordinator.run(importer, matcher: matcher)
        #expect(matcher.count == 1)                       // reused

        try await staging.clearMatchAttempt(source: "gog", externalID: "1")
        _ = try await coordinator.run(importer, matcher: matcher)
        #expect(matcher.count == 2)                       // re-queried after Re-match
    }

    // MARK: - Bundle expansion persisted / restored

    @Test(.timeLimit(.minutes(1)))
    func bundleExpansionRestoredWithoutReExpanding() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: [
            ImportStagingRow(source: "gog", externalID: "b1", name: "Some Trilogy", platform: "pc")])
        let bundleBest = ScanMatch(igdbID: 500, name: "Some Trilogy", releaseYear: nil, coverImageID: nil,
                                   platformSlugs: ["pc"], score: 0.97, matchedName: "Some Trilogy",
                                   gameType: .bundle)
        let matcher = CountingMatcher(ScanMatchOutcome(best: bundleBest, alternatives: [], bucket: .confident))
        let expander = CountingExpander(members: [
            IGDBSearchResult(id: 1, name: "Part I", releaseYear: nil, coverImageID: nil,
                             platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                             genres: [], alternativeNames: [], gameType: .mainGame),
            IGDBSearchResult(id: 2, name: "Part II", releaseYear: nil, coverImageID: nil,
                             platformIGDBIDs: [], platformAbbreviations: [], platformSlugs: [],
                             genres: [], alternativeNames: [], gameType: .mainGame),
        ])

        let r1 = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        #expect(expander.count == 1)
        #expect(r1.bundleExpansions["b1"]?.members.count == 2)

        let r2 = try await coordinator.run(importer, matcher: matcher, bundleExpander: expander)
        #expect(matcher.count == 1)                        // matcher not called again
        #expect(expander.count == 1)                       // expander not called again
        #expect(r2.bundleExpansions["b1"]?.members.map(\.title) == ["Part I", "Part II"])
    }

    // MARK: - Progress "already matched"

    @Test(.timeLimit(.minutes(1)))
    func progressReportsAlreadyMatchedCount() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let coordinator = ImportSyncCoordinator(staging: staging)
        let importer = FakeImporter(source: "gog", rows: rows("gog", 3))
        let matcher = CountingMatcher(confident(1, "Game"))

        _ = try await coordinator.run(importer, matcher: matcher)          // all 3 attempted
        try await staging.clearMatchAttempt(source: "gog", externalID: "1")  // one to re-query

        let recorder = ProgressRecorder()
        _ = try await coordinator.run(importer, matcher: matcher) { recorder.record($0) }
        #expect(matcher.count == 4)                        // 3 + 1 re-queried
        #expect(recorder.matchingDetails.contains { $0.contains("2 already matched") })
    }
}
