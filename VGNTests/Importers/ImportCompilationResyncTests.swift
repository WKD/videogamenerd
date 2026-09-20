import Foundation
import GRDB
import Testing
@testable import VGN

/// A committed compilation row must not re-list as *New* on the next review (D4, PLAN §5.1): the
/// commit marks the staging row matched (to the first member), so a re-sync lands it under
/// *Already matched*, and a second commit stays idempotent on `(source, external_id)`. No network.
@Suite(.serialized) struct ImportCompilationResyncTests {

    private func compilationItem() -> ImportCommitItem {
        ImportCommitItem(
            source: "gog", externalID: "b1", platformID: "pc", format: .digital,
            target: .compilation(title: "Some Trilogy", members: [
                CompilationMemberDraft(title: "Part I", igdbID: 1, position: 0),
                CompilationMemberDraft(title: "Part II", igdbID: 2, position: 1),
            ]))
    }

    @Test(.timeLimit(.minutes(1)))
    func committedCompilationBecomesAlreadyMatched() async throws {
        let db = try await ImportTestDB.makeSeeded()
        let staging = ImportStagingStore(db)
        try await staging.upsert([ImportStagingRow(source: "gog", externalID: "b1",
                                                   name: "Some Trilogy", platform: "pc")])
        // Before commit it is New.
        #expect(try await staging.titles(source: "gog").first { $0.externalID == "b1" }?.bucket == .new)

        let result = try await staging.commit([compilationItem()])
        #expect(result.gamesCreated == 2)
        #expect(result.productsAdded == 1)

        // After commit the staging row is matched → the next review lists it under Already matched.
        let row = try #require(try await staging.titles(source: "gog").first { $0.externalID == "b1" })
        #expect(row.bucket == .alreadyMatched)
        #expect(row.matchedGameID != nil)

        // A second commit is idempotent — no second compilation product.
        let second = try await staging.commit([compilationItem()])
        #expect(second.skippedExisting == 1)
        #expect(second.productsAdded == 0)
        let products = try await db.dbWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM products WHERE source = 'gog'") ?? -1
        }
        #expect(products == 1)
    }
}
