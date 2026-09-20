import Foundation
import Testing
@testable import VGN

/// Per-row **Re-match** in the shared import review sheet (PLAN §5.1, wave 16): a New row can be
/// re-matched through the injected matcher seam — it clears the persisted attempt and re-queries
/// exactly one title, updating just that row; it is cancellable; and it is hidden without a
/// matcher. No network — a counting fake matcher.
@MainActor
@Suite(.serialized)
struct ImportReviewRematchTests {

    private final class CountingMatcher: ImportMatcher, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        var lastRequest: ImportMatchRequest?
        let outcome: ScanMatchOutcome
        init(_ outcome: ScanMatchOutcome) { self.outcome = outcome }
        func match(_ request: ImportMatchRequest) async throws -> ScanMatchOutcome {
            lock.withLock { _count += 1; lastRequest = request }
            return outcome
        }
    }

    /// A single New row ("40" Penguin Quest) with no match, plus its staging + sync result.
    private func seedOneNewRow() async throws -> (ImportStagingStore, ImportSyncResult) {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        let rows = [ImportStagingRow(source: "gog", externalID: "40", name: "Penguin Quest",
                                     platform: "pc")]
        try await staging.upsert(rows)
        let result = ImportSyncResult(
            summary: ImportSyncSummary(source: "gog", stagedTotal: 1, newCount: 1),
            matches: [], rows: rows)
        return (staging, result)
    }

    private func confident(_ id: Int64, _ name: String) -> ScanMatchOutcome {
        ScanMatchOutcome(
            best: ScanMatch(igdbID: id, name: name, releaseYear: 2011, coverImageID: nil,
                            platformSlugs: ["pc"], score: 0.95, matchedName: name),
            alternatives: [ScanMatch(igdbID: id + 1, name: "\(name) 2", releaseYear: 2012,
                                     coverImageID: nil, platformSlugs: ["pc"], score: 0.7, matchedName: "\(name) 2")],
            bucket: .confident)
    }

    @Test(.timeLimit(.minutes(1)))
    func rematchClearsTheAttemptAndReQueriesExactlyOneTitle() async throws {
        let (staging, result) = try await seedOneNewRow()
        // A stale attempt exists — Re-match must clear it (and re-query).
        try await staging.recordMatchOutcome(
            source: "gog", externalID: "40",
            PersistedImportMatch(outcome: ScanMatchOutcome(best: nil, alternatives: [], bucket: .none), bundle: nil))
        let matcher = CountingMatcher(confident(701, "Penguin Quest"))
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                  result: result, rematchMatcher: matcher)
        await m.load()

        let before = m.rows.first { $0.externalID == "40" }
        #expect(before?.proposedMatch == nil)
        #expect(m.canRematch(before!))

        await m.rematch("40")?.value

        #expect(matcher.count == 1)                                   // exactly one title re-queried
        #expect(matcher.lastRequest?.title == "Penguin Quest")
        let after = m.rows.first { $0.externalID == "40" }
        #expect(after?.proposedMatch?.igdbID == 701)                  // the row updated
        #expect(after?.alternatives.count == 1)
        #expect(m.rematchingIDs.isEmpty)                              // spinner cleared
        // The fresh outcome was persisted (so a later sync reuses it, not re-queries).
        let attempts = try await staging.persistedAttempts(source: "gog")
        #expect(attempts["40"]?.match?.outcome.best?.igdbID == 701)
    }

    @Test(.timeLimit(.minutes(1)))
    func rematchIsCancellable() async throws {
        let (staging, result) = try await seedOneNewRow()
        let matcher = CountingMatcher(confident(701, "Penguin Quest"))
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging,
                                  result: result, rematchMatcher: matcher)
        await m.load()

        // Start then cancel before the task's first suspension resumes: the row must not update.
        let task = m.rematch("40")
        #expect(m.rematchingIDs.contains("40"))
        m.cancelRematch("40")
        #expect(m.rematchingIDs.isEmpty)
        await task?.value
        #expect(m.rows.first { $0.externalID == "40" }?.proposedMatch == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func rematchHiddenWithoutAMatcher() async throws {
        let (staging, result) = try await seedOneNewRow()
        let m = ImportReviewModel(source: "gog", sourceLabel: "GOG", staging: staging, result: result)
        await m.load()
        #expect(m.canRematch == false)                               // no matcher ⇒ affordance hidden
        let row = try #require(m.rows.first { $0.externalID == "40" })
        #expect(m.canRematch(row) == false)
        #expect(m.rematch("40") == nil)                              // and it is a no-op
    }
}
