import Foundation
import GRDB
import Testing
@testable import VGN

/// Bulk "Change Copy Format" (PLAN §13.3): a game with exactly one non-subscription single
/// copy is reformatted; a game with several is skipped; a PS Plus copy is never counted or
/// changed; the batch is exactly reversible.
@Suite(.serialized)
struct ChangeCopyFormatTests {
    private func store() throws -> LibraryStore {
        let store = LibraryStore(try AppDatabase.inMemory())
        return store
    }

    private func seed(_ store: LibraryStore) async throws {
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO platforms (id, name, short, manufacturer, group_name, kind, sort)
                VALUES ('ps5','PS5','PS5','Sony','Sony','console',1)
                """)
        }
    }

    @discardableResult
    private func game(_ store: LibraryStore, _ title: String) async throws -> Int64 {
        try await store.dbWriter.write { db in
            var g = GameRecord(title: title); try g.insert(db); return g.id!
        }
    }

    private func addCopy(_ store: LibraryStore, game: Int64, format: ProductFormat = .digital,
                         subscription: String? = nil, kind: String = "single") async throws -> Int64 {
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                INSERT INTO products (platform_id, kind, format, source, subscription)
                VALUES ('ps5', ?, ?, 'psn', ?)
                """, arguments: [kind, format.rawValue, subscription])
            let pid = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO product_games (product_id, game_id, position) VALUES (?, ?, 0)",
                           arguments: [pid, game])
            return pid
        }
    }

    private func format(_ store: LibraryStore, _ productID: Int64) async throws -> ProductFormat {
        try await store.dbReader.read { db in
            ProductFormat(rawValue: try String.fetchOne(db, sql: "SELECT format FROM products WHERE id = ?",
                                                        arguments: [productID]) ?? "") ?? .physical
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func singleCopyGameIsReformatted() async throws {
        let store = try store(); try await seed(store)
        let g = try await game(store, "Stray")
        let pid = try await addCopy(store, game: g, format: .digital)
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .physical)
        #expect(result.changed == 1)
        #expect(result.skipped == 0)
        #expect(try await format(store, pid) == .physical)
    }

    @Test(.timeLimit(.minutes(1)))
    func severalCopyGameIsSkippedAndUnchanged() async throws {
        let store = try store(); try await seed(store)
        let g = try await game(store, "Elden Ring")
        let a = try await addCopy(store, game: g, format: .digital)
        let b = try await addCopy(store, game: g, format: .physical)
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .rom)
        #expect(result.changed == 0)
        #expect(result.skipped == 1)
        #expect(try await format(store, a) == .digital)   // untouched
        #expect(try await format(store, b) == .physical)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscriptionCopyIsNeverCountedNorChanged() async throws {
        let store = try store(); try await seed(store)
        // One really-owned digital + one PS Plus copy → still "exactly one" non-sub copy.
        let g = try await game(store, "Fall Guys")
        let owned = try await addCopy(store, game: g, format: .digital)
        let plus = try await addCopy(store, game: g, format: .digital, subscription: "ps_plus")
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .physical)
        #expect(result.changed == 1)
        #expect(try await format(store, owned) == .physical)
        #expect(try await format(store, plus) == .digital)   // PS Plus copy untouched
    }

    @Test(.timeLimit(.minutes(1)))
    func onlySubscriptionCopyChangesNothing() async throws {
        let store = try store(); try await seed(store)
        let g = try await game(store, "PS Plus Only")
        let plus = try await addCopy(store, game: g, format: .digital, subscription: "ps_plus")
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .physical)
        #expect(result.changed == 0)
        #expect(result.skipped == 0)
        #expect(try await format(store, plus) == .digital)
    }

    @Test(.timeLimit(.minutes(1)))
    func compilationCopyIsNotAffected() async throws {
        let store = try store(); try await seed(store)
        let g = try await game(store, "In A Compilation")
        let comp = try await addCopy(store, game: g, format: .physical, kind: "compilation")
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .digital)
        #expect(result.changed == 0)
        #expect(try await format(store, comp) == .physical)
    }

    @Test(.timeLimit(.minutes(1)))
    func mixedBatchCountsAndRestoreReverts() async throws {
        let store = try store(); try await seed(store)
        let single = try await game(store, "One")
        let sPid = try await addCopy(store, game: single, format: .digital)
        let many = try await game(store, "Two")
        _ = try await addCopy(store, game: many, format: .digital)
        _ = try await addCopy(store, game: many, format: .physical)

        let result = try await store.changeCopyFormat(gameIDs: [single, many], to: .rom)
        #expect(result.changed == 1)
        #expect(result.skipped == 1)
        #expect(result.reverts == [CopyFormatChange(productID: sPid, previousFormat: .digital)])

        // Banner wording.
        #expect(LibraryActions.copyFormatBanner(result, format: .rom)
                == "1 changed to ROM · 1 skipped (several copies)")

        // Undo restores the prior format exactly.
        try await store.restoreCopyFormats(result.reverts)
        #expect(try await format(store, sPid) == .digital)
    }

    @Test(.timeLimit(.minutes(1)))
    func alreadyTargetFormatIsNotCounted() async throws {
        let store = try store(); try await seed(store)
        let g = try await game(store, "Already Digital")
        _ = try await addCopy(store, game: g, format: .digital)
        let result = try await store.changeCopyFormat(gameIDs: [g], to: .digital)
        #expect(result.changed == 0)
        #expect(result.skipped == 0)
        #expect(result.reverts.isEmpty)
    }
}
